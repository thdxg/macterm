@testable import Macterm
import XCTest

@MainActor
final class PaneTests: XCTestCase {
    private func shellName() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return (shell as NSString).lastPathComponent
    }

    func test_processTitle_defaults_to_shell_name_when_title_blank() {
        let p = Pane(projectPath: "/")
        p.title = ""
        XCTAssertEqual(p.processTitle, shellName())
    }

    func test_processTitle_defaults_to_shell_name_when_title_whitespace() {
        let p = Pane(projectPath: "/")
        p.title = "   \t\n"
        XCTAssertEqual(p.processTitle, shellName())
    }

    func test_processTitle_picks_first_non_path_token() {
        let p = Pane(projectPath: "/")
        p.title = "/Users/me vim file.swift"
        XCTAssertEqual(p.processTitle, "vim")
    }

    func test_processTitle_picks_first_meaningful_token() {
        let p = Pane(projectPath: "/")
        p.title = "git status"
        XCTAssertEqual(p.processTitle, "git")
    }

    func test_processTitle_skips_noise_tokens() {
        let p = Pane(projectPath: "/")
        p.title = ">>> /Users/me node server.js"
        // ">>>", "/Users/me" are noise / path — should pick "node".
        XCTAssertEqual(p.processTitle, "node")
    }

    func test_processTitle_falls_back_to_shell_when_all_paths() {
        let p = Pane(projectPath: "/")
        p.title = "/usr/bin ~/dev"
        XCTAssertEqual(p.processTitle, shellName())
    }

    func test_processTitle_treats_tilde_prefix_as_path() {
        let p = Pane(projectPath: "/")
        p.title = "~/dev cmd"
        XCTAssertEqual(p.processTitle, "cmd")
    }

    func test_sidebarSegmentTitle_matches_processTitle() {
        let p = Pane(projectPath: "/")
        p.title = "zsh"
        XCTAssertEqual(p.sidebarSegmentTitle, p.processTitle)
    }

    func test_init_stores_project_path() {
        let p = Pane(projectPath: "/tmp/foo")
        XCTAssertEqual(p.projectPath, "/tmp/foo")
    }

    func test_destroySurface_is_safe_when_nsView_is_nil() {
        let p = Pane(projectPath: "/")
        XCTAssertNil(p.nsView)
        p.destroySurface() // must not crash
        p.destroySurface() // idempotent
        XCTAssertNil(p.nsView)
    }
}
