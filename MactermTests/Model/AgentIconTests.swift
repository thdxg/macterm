import Foundation
@testable import Macterm
import Testing

@MainActor
struct AgentIconTests {
    @Test
    func matches_known_agent_process_names() {
        #expect(AgentIcon.match(processName: "claude") == .claude)
        #expect(AgentIcon.match(processName: "codex") == .codex)
        #expect(AgentIcon.match(processName: "opencode") == .opencode)
        #expect(AgentIcon.match(processName: "cursor-agent") == .cursor)
        #expect(AgentIcon.match(processName: "gemini") == .gemini)
        #expect(AgentIcon.match(processName: "copilot") == .copilot)
        #expect(AgentIcon.match(processName: "grok") == .grok)
    }

    @Test
    func match_is_case_insensitive() {
        #expect(AgentIcon.match(processName: "Claude") == .claude)
    }

    @Test
    func matches_suffixed_binary_names() {
        // brew's codex binary is `codex-aarch64-apple-darwin`; the kernel comm
        // truncates it to 15 chars.
        #expect(AgentIcon.match(processName: "codex-aarch64-a") == .codex)
        #expect(AgentIcon.match(processName: "claude.bak") == .claude)
    }

    @Test
    func prefix_match_requires_a_separator() {
        // A known name followed by more letters is a different program.
        #expect(AgentIcon.match(processName: "claudette") == nil)
        #expect(AgentIcon.match(processName: "grokify") == nil)
    }

    @Test
    func shells_and_ordinary_programs_do_not_match() {
        #expect(AgentIcon.match(processName: "zsh") == nil)
        #expect(AgentIcon.match(processName: "btop") == nil)
        #expect(AgentIcon.match(processName: nil) == nil)
    }

    @Test
    func comm_match_wins_without_reading_argv() {
        var argvRead = false
        let icon = AgentIcon.match(comm: "codex") { argvRead = true
            return nil
        }
        #expect(icon == .codex)
        #expect(!argvRead)
    }

    @Test
    func falls_back_to_argv0_when_comm_is_opaque() {
        // Claude Code's native install execs a versioned binary: comm is the
        // bare version, argv[0] stays `claude`.
        #expect(AgentIcon.match(comm: "2.1.207") { "claude" } == .claude)
        #expect(AgentIcon.match(comm: "2.1.207") { nil } == nil)
    }

    @Test
    func pane_caches_agent_across_steady_refreshes() {
        let pane = Pane(projectPath: "/", projectID: UUID())
        var argvReads = 0
        let argv0: () -> String? = { argvReads += 1
            return "claude"
        }
        pane.applyForegroundRefresh(name: "2.1.207", foregroundPID: 42, argv0: argv0)
        #expect(pane.agentIcon == .claude)
        #expect(argvReads == 1)
        // Same pid + comm on the next tick: cached, argv untouched.
        pane.applyForegroundRefresh(name: "2.1.207", foregroundPID: 42, argv0: argv0)
        #expect(argvReads == 1)
        // Agent exits, shell takes the foreground.
        pane.applyForegroundRefresh(name: "zsh", foregroundPID: 7, argv0: { nil })
        #expect(pane.agentIcon == nil)
    }

    @Test
    func pane_has_no_agent_without_a_foreground_pid() {
        let pane = Pane(projectPath: "/", projectID: UUID())
        pane.applyForegroundRefresh(name: nil, foregroundPID: nil, argv0: { "claude" })
        #expect(pane.agentIcon == nil)
    }

    @Test
    func tab_agentIcon_prefers_focused_pane() throws {
        let tab = TerminalTab(projectPath: "/", projectID: UUID())
        let firstPane = try #require(tab.splitRoot.allPanes().first)
        firstPane.applyForegroundRefresh(name: "codex", foregroundPID: 1)
        let newID = try #require(tab.split(paneID: firstPane.id, direction: .horizontal))
        let newPane = try #require(tab.splitRoot.findPane(id: newID))
        newPane.applyForegroundRefresh(name: "claude", foregroundPID: 2)
        tab.focusPane(newID)
        #expect(tab.agentIcon == .claude)
    }

    @Test
    func tab_agentIcon_falls_back_to_any_pane_running_an_agent() throws {
        let tab = TerminalTab(projectPath: "/", projectID: UUID())
        let firstPane = try #require(tab.splitRoot.allPanes().first)
        let newID = try #require(tab.split(paneID: firstPane.id, direction: .horizontal))
        firstPane.applyForegroundRefresh(name: "grok", foregroundPID: 1)
        try #require(tab.splitRoot.findPane(id: newID)).applyForegroundRefresh(name: "zsh", foregroundPID: 2)
        tab.focusPane(newID)
        #expect(tab.agentIcon == .grok)
    }

    @Test
    func tab_agentIcon_is_nil_when_no_agent_runs() throws {
        let tab = TerminalTab(projectPath: "/", projectID: UUID())
        try #require(tab.splitRoot.allPanes().first).applyForegroundRefresh(name: "zsh", foregroundPID: 1)
        #expect(tab.agentIcon == nil)
    }
}
