import Foundation
@testable import Macterm
import Testing

/// Tests for the pane's title model: the OSC-title provenance gate
/// (`receiveReportedTitle`) and its expiry (`applyForegroundRefresh`).
/// Both are exercised through their testable cores, with the foreground
/// pid / program-pid lookups passed in instead of read from live surfaces.
@MainActor
struct PaneTitleTests {
    private func makePane() -> Pane {
        Pane(projectPath: "/", projectID: UUID())
    }

    // MARK: - receiveReportedTitle (provenance gate)

    @Test
    func title_from_program_is_adopted() {
        let pane = makePane()
        pane.receiveReportedTitle("✳ Fix tab switcher", programPID: 42)
        #expect(pane.programTitle == "✳ Fix tab switcher")
        #expect(pane.displayTitle == "✳ Fix tab switcher")
    }

    @Test
    func title_from_shell_prompt_is_ignored() {
        let pane = makePane()
        // programPID nil = the foreground process is the shell (prompt churn).
        pane.receiveReportedTitle("~/dev/macterm", programPID: nil)
        #expect(pane.programTitle == nil)
    }

    @Test
    func blank_title_is_ignored() {
        let pane = makePane()
        pane.receiveReportedTitle("   ", programPID: 42)
        #expect(pane.programTitle == nil)
    }

    @Test
    func title_is_trimmed() {
        let pane = makePane()
        pane.receiveReportedTitle("  hello \n", programPID: 42)
        #expect(pane.programTitle == "hello")
    }

    @Test
    func same_program_can_update_its_title() {
        let pane = makePane()
        pane.receiveReportedTitle("first", programPID: 42)
        pane.receiveReportedTitle("second", programPID: 42)
        #expect(pane.programTitle == "second")
    }

    // MARK: - applyForegroundRefresh (expiry)

    @Test
    func title_survives_while_its_pid_holds_the_foreground() {
        let pane = makePane()
        pane.receiveReportedTitle("session", programPID: 42)
        pane.applyForegroundRefresh(name: "claude", foregroundPID: 42)
        #expect(pane.programTitle == "session")
    }

    @Test
    func title_expires_when_foreground_returns_to_shell() {
        let pane = makePane()
        pane.receiveReportedTitle("session", programPID: 42)
        pane.applyForegroundRefresh(name: "nu", foregroundPID: 7, foregroundIsShell: true)
        #expect(pane.programTitle == nil)
        // Display falls back to the process name.
        #expect(pane.displayTitle == "nu")
    }

    @Test
    func title_expires_when_a_different_program_takes_over() {
        let pane = makePane()
        pane.receiveReportedTitle("session", programPID: 42)
        // claude exits and btop starts between two polls: the pid changed,
        // so claude's title must not be attributed to btop.
        pane.applyForegroundRefresh(name: "btop", foregroundPID: 43)
        #expect(pane.programTitle == nil)
        #expect(pane.displayTitle == "btop")
    }

    @Test
    func title_expires_when_surface_is_gone() {
        let pane = makePane()
        pane.receiveReportedTitle("session", programPID: 42)
        pane.applyForegroundRefresh(name: nil, foregroundPID: nil)
        #expect(pane.programTitle == nil)
    }

    // MARK: - displayTitle

    @Test
    func displayTitle_falls_back_to_process_name_without_a_program_title() {
        let pane = makePane()
        pane.applyForegroundRefresh(name: "hx", foregroundPID: 9)
        #expect(pane.displayTitle == "hx")
    }

    @Test
    func tab_autoTitle_uses_program_title_for_its_segment() {
        let pane = makePane()
        let tab = TerminalTab(id: UUID(), splitRoot: .pane(pane), focusedPaneID: pane.id)
        pane.receiveReportedTitle("✳ session", programPID: 42)
        #expect(tab.autoTitle == "✳ session")
    }
}
