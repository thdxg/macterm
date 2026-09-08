import AppKit
import Foundation
@testable import Macterm
import Testing

@MainActor
struct SidebarPresentationStateTests {
    @Test
    func completing_rename_returns_one_shared_draft_and_clears_it() {
        let state = SidebarPresentationState()
        let tabID = UUID()

        state.beginRename(.tab(tabID), text: "draft", originalCustomTitle: "old")
        state.renameText = "final"

        let result = state.completeRename(.tab(tabID))
        #expect(result?.text == "final")
        #expect(result?.originalCustomTitle == "old")
        #expect(state.renameTarget == nil)
    }

    @Test
    func unrelated_row_cannot_consume_the_shared_rename_draft() {
        let state = SidebarPresentationState()
        let tabID = UUID()

        state.beginRename(.tab(tabID), text: "draft")

        #expect(state.completeRename(.project(UUID())) == nil)
        #expect(state.isRenaming(.tab(tabID)))
        #expect(state.renameText == "draft")
    }

    @Test
    func ordinary_overlay_dismissal_discards_the_rename_draft() {
        let state = SidebarPresentationState()
        state.beginRename(.tab(UUID()), text: "draft")

        state.discardRename()

        #expect(state.renameTarget == nil)
        #expect(state.renameText.isEmpty)
    }

    @Test
    func selection_and_expansion_live_on_the_shared_state() {
        let state = SidebarPresentationState()
        let projectID = UUID()
        let tabID = UUID()

        state.expandedProjects.insert(projectID)
        state.selection = [.tab(projectID: projectID, tabID: tabID)]
        state.scrollPosition = .tab(projectID: projectID, tabID: tabID)

        #expect(state.expandedProjects == [projectID])
        #expect(state.selection == [.tab(projectID: projectID, tabID: tabID)])
        #expect(state.scrollPosition == .tab(projectID: projectID, tabID: tabID))
    }

    @Test
    func a_shift_click_range_spans_every_row_between_the_two_ends() {
        let state = SidebarPresentationState()
        let projectID = UUID()
        let tabs = (0 ..< 5).map { _ in UUID() }
        state.orderedItems = [.project(projectID)]
            + tabs.map { .tab(projectID: projectID, tabID: $0) }

        let range = state.itemRange(
            from: .tab(projectID: projectID, tabID: tabs[0]),
            to: .tab(projectID: projectID, tabID: tabs[3])
        )

        #expect(range == tabs[0 ... 3].map { .tab(projectID: projectID, tabID: $0) })
    }

    @Test
    func a_shift_click_range_reads_the_same_dragged_upward() {
        let state = SidebarPresentationState()
        let projectID = UUID()
        let tabs = (0 ..< 3).map { _ in UUID() }
        state.orderedItems = tabs.map { .tab(projectID: projectID, tabID: $0) }

        let up = state.itemRange(
            from: .tab(projectID: projectID, tabID: tabs[2]),
            to: .tab(projectID: projectID, tabID: tabs[0])
        )

        #expect(up == state.orderedItems)
    }

    @Test
    func a_range_off_a_vanished_row_is_nil_rather_than_a_wrong_span() {
        let state = SidebarPresentationState()
        let projectID = UUID()
        let tabID = UUID()
        state.orderedItems = [.tab(projectID: projectID, tabID: tabID)]

        // The anchor's tab was closed (or its project collapsed) since the
        // click that set it — the caller selects just the clicked row.
        #expect(state.itemRange(
            from: .tab(projectID: projectID, tabID: UUID()),
            to: .tab(projectID: projectID, tabID: tabID)
        ) == nil)
    }

    @Test
    func a_plain_click_replaces_the_whole_selection() {
        let state = SidebarPresentationState()
        let projects = (0 ..< 3).map { _ in UUID() }
        state.orderedItems = projects.map { .project($0) }
        state.selection = [.project(projects[0]), .project(projects[1])]

        state.selectRow(.project(projects[2]), modifiers: [])

        #expect(state.selection == [.project(projects[2])])
    }

    @Test
    func a_command_click_toggles_one_row_without_disturbing_the_rest() {
        let state = SidebarPresentationState()
        let projects = (0 ..< 2).map { _ in UUID() }
        state.orderedItems = projects.map { .project($0) }
        state.selection = [.project(projects[0])]

        state.selectRow(.project(projects[1]), modifiers: .command)
        #expect(state.selection == [.project(projects[0]), .project(projects[1])])

        state.selectRow(.project(projects[1]), modifiers: .command)
        #expect(state.selection == [.project(projects[0])])
    }

    @Test
    func a_shift_click_selects_every_row_between_the_anchor_and_the_click() {
        let state = SidebarPresentationState()
        let projectID = UUID()
        let tabs = (0 ..< 4).map { _ in UUID() }
        state.orderedItems = [.project(projectID)]
            + tabs.map { .tab(projectID: projectID, tabID: $0) }
        state.selectionAnchor = .tab(projectID: projectID, tabID: tabs[0])

        state.selectRow(.tab(projectID: projectID, tabID: tabs[3]), modifiers: .shift)

        // All four, not just the two ends — the bulk close acts on this set.
        #expect(state.selection.count == 4)
        #expect(state.selection == Set(tabs.map { .tab(projectID: projectID, tabID: $0) }))
    }

    @Test
    func a_shift_click_spans_a_project_header_and_its_tabs_alike() {
        let state = SidebarPresentationState()
        let projectID = UUID()
        let tabID = UUID()
        state.orderedItems = [.project(projectID), .tab(projectID: projectID, tabID: tabID)]
        state.selectionAnchor = .project(projectID)

        state.selectRow(.tab(projectID: projectID, tabID: tabID), modifiers: .shift)

        #expect(state.selection == Set(state.orderedItems))
    }

    @Test
    func a_shift_click_with_no_anchor_selects_only_the_clicked_row() {
        let state = SidebarPresentationState()
        let projectID = UUID()
        state.orderedItems = [.project(projectID)]

        state.selectRow(.project(projectID), modifiers: .shift)

        #expect(state.selection == [.project(projectID)])
    }

    /// The flag is one process-wide value (it gates a global retry loop), so
    /// these two set it from a known state and hand it back — a sibling test
    /// that leaves a rename open must not decide whether they pass.
    @Test
    func an_open_rename_holds_focus_restoration_off_until_it_ends() {
        FocusRestoration.isEditingInlineName = false
        defer { FocusRestoration.isEditingInlineName = false }
        let state = SidebarPresentationState()
        let tabID = UUID()

        state.beginRename(.tab(tabID), text: "draft")
        #expect(FocusRestoration.isEditingInlineName)

        _ = state.completeRename(.tab(tabID))
        #expect(!FocusRestoration.isEditingInlineName)
    }

    @Test
    func cancelling_a_rename_also_releases_focus_restoration() {
        FocusRestoration.isEditingInlineName = false
        defer { FocusRestoration.isEditingInlineName = false }
        let state = SidebarPresentationState()
        let tabID = UUID()

        state.beginRename(.tab(tabID), text: "draft")
        #expect(state.cancelRename(.tab(tabID)))

        #expect(!FocusRestoration.isEditingInlineName)
    }
}
