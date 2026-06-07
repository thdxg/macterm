import Foundation
@testable import Macterm
import Testing

@MainActor
struct PaneTests {
    private func shellName() -> String {
        // Mirror Pane.defaultShellName: the login shell from the password
        // database, not $SHELL (which is the app-launcher's shell).
        let loginShell = getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) }
        let shell = (loginShell?.isEmpty == false ? loginShell : nil)
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
        return (shell as NSString).lastPathComponent
    }

    @Test
    func processTitle_uses_foreground_process_when_running() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.foregroundProcessName = "btop"
        #expect(p.processTitle == "btop")
    }

    @Test
    func processTitle_defaults_to_shell_name_when_idle() {
        // No foreground process (idle at a prompt) → the shell name. The OSC
        // title is never consulted.
        let p = Pane(projectPath: "/", projectID: UUID())
        p.foregroundProcessName = nil
        #expect(p.processTitle == shellName())
    }

    @Test
    func processTitle_treats_empty_foreground_name_as_idle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.foregroundProcessName = ""
        #expect(p.processTitle == shellName())
    }

    @Test
    func sidebarSegmentTitle_matches_processTitle() {
        let p = Pane(projectPath: "/", projectID: UUID())
        p.foregroundProcessName = "nvim"
        #expect(p.sidebarSegmentTitle == p.processTitle)
    }

    @Test
    func init_stores_project_path() {
        let p = Pane(projectPath: "/tmp/foo", projectID: UUID())
        #expect(p.projectPath == "/tmp/foo")
    }

    @Test
    func destroySurface_is_safe_when_nsView_is_nil() {
        let p = Pane(projectPath: "/", projectID: UUID())
        #expect(p.nsView == nil)
        p.destroySurface() // must not crash
        p.destroySurface() // idempotent
        #expect(p.nsView == nil)
    }
}
