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
    func eager_launch_expands_every_project_only_once() {
        let state = SidebarPresentationState()
        let firstID = UUID()
        let secondID = UUID()

        state.restoreExpansionOnce(
            projectIDs: [firstID, secondID],
            activeProjectID: firstID,
            restoreAllProjects: true
        )
        #expect(state.expandedProjects == [firstID, secondID])

        // A later overlay appearance must preserve a user collapse.
        state.expandedProjects.remove(secondID)
        state.restoreExpansionOnce(
            projectIDs: [firstID, secondID],
            activeProjectID: firstID,
            restoreAllProjects: true
        )
        #expect(state.expandedProjects == [firstID])
    }

    @Test
    func lazy_launch_expands_only_the_active_project() {
        let state = SidebarPresentationState()
        let activeID = UUID()

        state.restoreExpansionOnce(
            projectIDs: [activeID, UUID()],
            activeProjectID: activeID,
            restoreAllProjects: false
        )

        #expect(state.expandedProjects == [activeID])
    }
}
