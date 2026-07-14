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
}
