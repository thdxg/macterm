import Foundation
@testable import Macterm
import Testing

struct PasswordPromptIdentityTests {
    @Test
    func prompt_line_is_the_last_non_empty_viewport_line() {
        let screen = "~ ❯ ssh prod\nethan@prod.example.com's   password: \n\n\n"
        #expect(PasswordPromptIdentity.promptLine(fromViewport: screen) == "ethan@prod.example.com's password:")
        #expect(PasswordPromptIdentity.promptLine(fromViewport: "\n  \n") == nil)
    }

    @Test
    func prompt_line_is_capped() {
        let long = String(repeating: "x", count: 500)
        #expect(PasswordPromptIdentity.promptLine(fromViewport: long)?.count == PasswordPromptIdentity.maxPromptLength)
    }

    /// A program at `path`, as the process table reports it.
    private func program(_ command: String, protected: Bool = true) -> PasswordAsker {
        let path = String(command.split(separator: " ").first ?? "")
        return .program(path: path, command: command, isProtected: protected)
    }

    @Test
    func entry_is_the_command_plus_the_prompt() {
        let id = PasswordPromptIdentity.entryID(prompt: "ethan@prod's password:", asker: program("/usr/bin/ssh  prod"))
        #expect(id == PasswordEntryID(command: "/usr/bin/ssh prod", prompt: "ethan@prod's password:"))
        #expect(id?.title == "ssh prod")
        #expect(PasswordPromptIdentity.declaredEntryID(prompt: "ethan@prod's password:", command: "ssh  prod")
            == PasswordEntryID(command: "ssh prod", prompt: "ethan@prod's password:"))
    }

    @Test
    func account_and_title_come_from_the_command_and_prompt() {
        let id = PasswordEntryID(command: "ssh prod", prompt: "ethan@prod's password:")
        #expect(id.account == "ssh prod — ethan@prod's password:")
        #expect(id.title == "ssh prod")
    }

    @Test
    func a_resolved_program_path_is_shown_by_name() {
        let id = PasswordEntryID(command: "/opt/homebrew/Cellar/python@3.14/Python /tmp/login.py", prompt: "Password:")
        #expect(id.displayCommand == "Python /tmp/login.py")
        #expect(PasswordEntryID(command: "sudo", prompt: "Password:").displayCommand == "sudo")
        #expect(PasswordEntryID(command: "ssh prod", prompt: "p:").displayCommand == "ssh prod")
        #expect(PasswordEntryID(command: nil, prompt: "p:").title == "p:")
    }

    @Test
    func an_ssh_shows_without_the_options_macterms_wrapper_added() {
        // `ssh demo-box` typed into a shell with ssh-env on runs as this.
        let wrapped = "/usr/bin/ssh -o SetEnv=TERM=xterm-ghostty -o SendEnv=COLORTERM -o SendEnv=TERM_PROGRAM "
            + "-o SendEnv=TERM_PROGRAM_VERSION -- demo-box"
        let id = PasswordEntryID(command: wrapped, prompt: "demo@localhost's password:")
        #expect(id.displayCommand == "ssh demo-box")
        #expect(id.title == "ssh demo-box")
        #expect(id.command == wrapped, "matching keeps the full argv")
        // The user's own options stay, and so does anything else ssh runs with.
        #expect(PasswordEntryID(
            command: "ssh -o SetEnv=TERM=xterm-256color -o SendEnv=COLORTERM -o SendEnv=TERM_PROGRAM "
                + "-o SendEnv=TERM_PROGRAM_VERSION -- -p 2222 prod uptime",
            prompt: "p:"
        ).displayCommand == "ssh -- -p 2222 prod uptime")
        #expect(PasswordEntryID(command: "/usr/bin/ssh -- prod", prompt: "p:").displayCommand == "ssh prod")
        #expect(PasswordEntryID(command: "/usr/bin/ssh -o SendEnv=COLORTERM prod", prompt: "p:").displayCommand
            == "ssh -o SendEnv=COLORTERM prod")
        // Only ssh is unwrapped.
        #expect(PasswordEntryID(command: "/usr/bin/env -- prod", prompt: "p:").displayCommand == "env -- prod")
    }

    @Test
    func one_command_asking_twice_files_two_entries() {
        let bastion = PasswordPromptIdentity.entryID(prompt: "ethan@bastion's password:", asker: program("/usr/bin/ssh -J bastion prod"))
        let prod = PasswordPromptIdentity.entryID(prompt: "ethan@prod's password:", asker: program("/usr/bin/ssh -J bastion prod"))
        #expect(bastion != prod)
    }

    @Test
    func sudo_files_under_the_bare_word() {
        let update = PasswordPromptIdentity.entryID(prompt: "Password:", asker: program("/usr/bin/sudo apt update"))
        let upgrade = PasswordPromptIdentity.entryID(prompt: "Password:", asker: program("/usr/bin/sudo -E make install"))
        #expect(update == PasswordEntryID(command: "sudo", prompt: "Password:"))
        #expect(update == upgrade)
        // A command that merely mentions sudo is not sudo.
        #expect(PasswordPromptIdentity.entryID(prompt: "Password:", asker: program("/usr/bin/man sudo"))?.command == "/usr/bin/man sudo")
    }

    @Test
    func a_sudo_the_user_could_have_replaced_keeps_its_own_entries() {
        let fake = PasswordPromptIdentity.entryID(prompt: "Password:", asker: program("/Users/e/bin/sudo apt update", protected: false))
        #expect(fake == PasswordEntryID(command: "/Users/e/bin/sudo apt update", prompt: "Password:"))
        // And it doesn't pass for the real one in the bubble.
        #expect(fake?.displayCommand == "/Users/e/bin/sudo apt update")
        #expect(PasswordEntryID(command: "\(NSHomeDirectory())/bin/sudo -E ls", prompt: "p:").displayCommand == "~/bin/sudo -E ls")
        #expect(PasswordEntryID(command: "/opt/homebrew/bin/sudo", prompt: "p:").displayCommand == "/opt/homebrew/bin/sudo")
    }

    @Test
    func key_passphrase_belongs_to_the_key_not_the_command() {
        let prompt = "Enter passphrase for key '/Users/e/.ssh/id_ed25519':"
        let ssh = PasswordPromptIdentity.entryID(prompt: prompt, asker: program("/usr/bin/ssh prod"))
        let add = PasswordPromptIdentity.entryID(prompt: prompt, asker: program("/usr/bin/ssh-add"))
        #expect(ssh?.command == nil)
        #expect(ssh == add)
        #expect(PasswordPromptIdentity.isKeyPassphrase("Enter passphrase for /Users/e/.ssh/id_rsa:"))
        #expect(!PasswordPromptIdentity.isKeyPassphrase("Enter password:"))
    }

    @Test
    func a_passphrase_asked_by_a_replaceable_program_is_filed_under_that_program() {
        let prompt = "Enter passphrase for key '/Users/e/.ssh/id_ed25519':"
        let brew = "/opt/homebrew/Cellar/openssh/10.0p1/bin/ssh"
        let prod = PasswordPromptIdentity.entryID(prompt: prompt, asker: program("\(brew) prod", protected: false))
        let staging = PasswordPromptIdentity.entryID(prompt: prompt, asker: program("\(brew) staging", protected: false))
        #expect(prod == PasswordEntryID(command: brew, prompt: prompt), "one entry per key for that program")
        #expect(prod == staging)
        #expect(prod?.displayCommand == "ssh")
        // A remote project's ssh whose client couldn't be read keeps the connection.
        let remote = PasswordPromptIdentity.entryID(
            prompt: prompt,
            asker: .program(path: "", command: "ssh e@host", isProtected: false)
        )
        #expect(remote == PasswordEntryID(command: "ssh e@host", prompt: prompt))
    }

    @Test
    func the_shell_itself_files_by_prompt_alone_and_an_unreadable_asker_files_nothing() {
        // A shell builtin (`read -s`) leaves no foreground command.
        #expect(PasswordPromptIdentity.entryID(prompt: "Vault password:", asker: .shell) == PasswordEntryID(
            command: nil,
            prompt: "Vault password:"
        ))
        #expect(PasswordPromptIdentity.entryID(prompt: "Vault password:", asker: .unknown) == nil)
    }

    @Test
    func a_declared_entry_collapses_like_a_detected_one() {
        #expect(PasswordPromptIdentity.declaredEntryID(prompt: "Password:", command: "sudo apt update")
            == PasswordEntryID(command: "sudo", prompt: "Password:"))
        #expect(PasswordPromptIdentity.declaredEntryID(prompt: "Enter passphrase for key '/k':", command: "ssh prod").command == nil)
        #expect(PasswordPromptIdentity.declaredEntryID(prompt: "Vault password:", command: nil).command == nil)
        #expect(PasswordPromptIdentity.declaredEntryID(prompt: "Vault password:", command: "  ").command == nil)
    }

    @Test
    func one_time_codes_are_recognized() {
        #expect(PasswordPromptIdentity.isOneTimeCode("Verification code:"))
        #expect(PasswordPromptIdentity.isOneTimeCode("(ethan@host) Enter OTP:"))
        #expect(PasswordPromptIdentity.isOneTimeCode("Two-factor code:"))
        #expect(!PasswordPromptIdentity.isOneTimeCode("ethan@host's password:"))
        #expect(!PasswordPromptIdentity.isOneTimeCode("Enter passphrase for key '/k':"))
    }

    @Test
    func remote_command_names_the_connection() {
        #expect(PasswordPromptIdentity.remoteCommand(user: "ethan", host: "prod") == "ssh ethan@prod")
        #expect(PasswordPromptIdentity.remoteCommand(user: nil, host: "prod") == "ssh prod")
    }
}

struct PasswordLineCaptureTests {
    private func run(_ inputs: [PasswordKeyInput]) -> (PasswordLineCapture, PasswordLineCapture.Outcome) {
        var capture = PasswordLineCapture()
        var outcome = PasswordLineCapture.Outcome.editing
        for input in inputs {
            outcome = capture.apply(input)
        }
        return (capture, outcome)
    }

    @Test
    func typed_text_submits_on_return() {
        let (_, outcome) = run([.text("hun"), .text("ter"), .text("2"), .submit])
        #expect(outcome == .submitted("hunter2"))
    }

    @Test
    func line_editing_mirrors_the_tty() {
        #expect(run([.text("abcX"), .backspace, .text("d"), .submit]).1 == .submitted("abcd"))
        #expect(run([.text("wrong"), .killLine, .text("right"), .submit]).1 == .submitted("right"))
        #expect(run([.text("one two  "), .killWord, .text("three"), .submit]).1 == .submitted("one three"))
        #expect(run([.backspace, .text("a"), .submit]).1 == .submitted("a"))
    }

    @Test
    func a_pasted_line_end_submits() {
        #expect(run([.text("pass\nignored")]).1 == .submitted("pass"))
    }

    @Test
    func cancel_discards_the_line() {
        let (capture, outcome) = run([.text("secret"), .cancel])
        #expect(outcome == .cancelled)
        #expect(capture.buffer.isEmpty)
    }

    @Test
    func an_unmirrorable_key_taints_the_capture() {
        let (capture, outcome) = run([.text("abc"), .unknown, .text("d"), .submit])
        #expect(capture.isTainted)
        #expect(outcome == .submitted(""))
        #expect(run([.text("abc"), .escape, .submit]).1 == .submitted(""))
    }

    @Test
    func return_and_a_pasted_newline_end_the_line() {
        #expect(PasswordKeyInput.submit.endsLine)
        #expect(PasswordKeyInput.text("hunter2\n").endsLine)
        #expect(!PasswordKeyInput.text("hunter2").endsLine)
        #expect(!PasswordKeyInput.cancel.endsLine)
        #expect(!PasswordKeyInput.killLine.endsLine)
    }
}

struct PasswordSubmissionJudgeTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1000)
    private var judge: PasswordSubmissionJudge {
        PasswordSubmissionJudge(submittedPrompt: "ethan@prod's password:", submittedAt: start)
    }

    private func observe(
        after seconds: TimeInterval,
        atPrompt: Bool = false,
        prompt: String? = nil,
        output: [String] = [],
        exit: Int32? = nil
    ) -> PasswordSubmissionJudge.Verdict {
        judge.evaluate(.init(
            now: start.addingTimeInterval(seconds),
            atPasswordPrompt: atPrompt,
            currentPrompt: prompt,
            outputAfterPrompt: output,
            exitCode: exit
        ))
    }

    @Test
    func the_same_prompt_again_with_a_rejection_line_is_a_failure() {
        let rejected = ["Permission denied, please try again."]
        #expect(observe(after: 2, atPrompt: true, prompt: "ethan@prod's password:", output: rejected) == .failed)
        // Printed before the settle window closes, it is still a rejection.
        #expect(observe(after: 0.05, atPrompt: true, prompt: "ethan@prod's password:", output: rejected) == .failed)
    }

    @Test
    func the_same_prompt_again_without_a_rejection_is_the_next_read() {
        // git over HTTPS asks the identical prompt once per connection; a push
        // opens two. The first password was accepted.
        #expect(observe(after: 2, atPrompt: true, prompt: "ethan@prod's password:") == .succeeded)
    }

    @Test
    func a_different_prompt_next_is_a_success() {
        #expect(observe(after: 1, atPrompt: true, prompt: "ethan@next-hop's password:") == .succeeded)
    }

    @Test
    func the_prompt_still_up_right_after_return_is_the_same_read() {
        #expect(observe(after: 0.1, atPrompt: true, prompt: "ethan@prod's password:") == .pending)
    }

    @Test
    func output_without_a_failure_is_a_success() {
        #expect(observe(after: 1, output: ["Last login: Sat Sep 26 on ttys003", "prod ~ $"]) == .succeeded)
        #expect(observe(after: 0.1, output: ["Last login: …"]) == .pending)
    }

    @Test
    func failure_lines_fail() {
        #expect(observe(after: 3, output: ["Permission denied, please try again."]) == .failed)
        #expect(observe(after: 3, output: ["Sorry, try again."]) == .failed)
        #expect(observe(after: 3, output: ["sudo: 3 incorrect password attempts"]) == .failed)
    }

    @Test
    func a_failure_word_deep_in_a_banner_is_not_a_failure() {
        // The rejection is always on the line after the prompt; a MOTD that
        // says "denied" four lines down is a successful login's banner.
        let banner = ["Welcome to prod", "Last login: Sat", "* * * NOTICE * * *", "Unauthorized access is denied."]
        #expect(observe(after: 1, output: banner) == .succeeded)
        #expect(observe(after: 1, output: Array(banner.suffix(1))) == .failed)
    }

    @Test
    func an_exit_code_judges_the_command_not_the_password() {
        #expect(observe(after: 0.1, exit: 0) == .succeeded)
        // `sudo grep -q`, `sudo test -f`, `ssh host cmd`: the password was
        // accepted and the command then exited nonzero on its own account.
        #expect(observe(after: 0.1, exit: 1) == .succeeded)
        #expect(observe(after: 0.1, output: ["granted"], exit: 1) == .succeeded)
        // A rejection line still fails, whatever the exit code.
        #expect(observe(after: 0.1, output: ["Sorry, try again.", "sudo: 3 incorrect password attempts"], exit: 1) == .failed)
        // -1: shell integration couldn't read the status; not a verdict.
        #expect(observe(after: 0.1, exit: -1) == .pending)
    }

    @Test
    func settle_decides_now_and_never_stays_pending() {
        // Typing at the prompt right after Return: the read is over.
        #expect(judge.settle(.init(
            now: start.addingTimeInterval(0.05),
            atPasswordPrompt: true,
            currentPrompt: "ethan@prod's password:",
            outputAfterPrompt: [],
            exitCode: nil
        )) == .succeeded)
        #expect(judge.settle(.init(
            now: start.addingTimeInterval(0.05),
            atPasswordPrompt: true,
            currentPrompt: "ethan@prod's password:",
            outputAfterPrompt: ["Permission denied, please try again."],
            exitCode: nil
        )) == .failed)
    }

    @Test
    func the_tty_leaving_line_mode_is_a_success() {
        /// A remote project's login: ssh goes raw to relay the session, and
        /// zmx repaints the screen, so nothing is ever drawn below the prompt.
        func lineModeLeft(after seconds: TimeInterval, output: [String] = []) -> PasswordSubmissionJudge.Verdict {
            judge.evaluate(.init(
                now: start.addingTimeInterval(seconds),
                atPasswordPrompt: false,
                currentPrompt: nil,
                outputAfterPrompt: output,
                exitCode: nil,
                inputIsNonCanonical: true
            ))
        }
        #expect(lineModeLeft(after: 1) == .succeeded)
        #expect(lineModeLeft(after: 0.1) == .pending, "not before the settle window")
        #expect(lineModeLeft(after: 1, output: ["Permission denied, please try again."]) == .failed)
        // The same silence with the tty still in line mode proves nothing.
        #expect(observe(after: 1) == .pending)
    }

    @Test
    func silence_times_out_undetermined() {
        #expect(observe(after: 5) == .pending)
        #expect(observe(after: PasswordSubmissionJudge.timeout) == .undetermined)
    }

    @Test
    func output_is_what_the_transcript_gained_since_the_submission() {
        // The viewport pads with blank rows; the end is the last real line.
        let atReturn = "~ $ ssh prod\nethan@prod's password:\n\n\n"
        let end = PasswordSubmissionJudge.transcriptEnd(atReturn)
        #expect(end == 2)
        // A rejection re-prompts with the identical line: searching for the
        // prompt would find the second copy and see nothing after it.
        let rejected = "~ $ ssh prod\nethan@prod's password:\nPermission denied, please try again.\nethan@prod's password:\n\n"
        #expect(PasswordSubmissionJudge.output(since: end, in: rejected) == [
            "Permission denied, please try again.",
            "ethan@prod's password:",
        ])
        #expect(PasswordSubmissionJudge.output(since: end, in: atReturn).isEmpty)
        #expect(PasswordSubmissionJudge.transcriptEnd("\n \n") == 0)
    }
}

@MainActor
struct PasswordVaultTests {
    @Test
    func save_list_read_remove() {
        let vault = PasswordVault(store: InMemoryPasswordStore())
        let id = PasswordEntryID(command: "ssh prod", prompt: "ethan@prod's password:")
        #expect(!vault.contains(id))
        #expect(vault.save("hunter2", for: id))
        #expect(vault.contains(id))
        #expect(vault.password(for: id) == "hunter2")
        vault.save("hunter3", for: id)
        #expect(vault.entries.count == 1)
        #expect(vault.password(for: id) == "hunter3")
        vault.remove(id)
        #expect(!vault.contains(id))
        #expect(vault.password(for: id) == nil)
    }

    @Test
    func update_refiles_an_entry_and_can_change_its_password() {
        let vault = PasswordVault(store: InMemoryPasswordStore())
        let old = PasswordEntryID(command: "ssh prod", prompt: "ethan@prod's password:")
        let new = PasswordEntryID(command: "ssh prod.example.com", prompt: "ethan@prod's password:")
        vault.save("hunter2", for: old)
        #expect(vault.update(old, to: new, password: "hunter2"))
        #expect(!vault.contains(old))
        #expect(vault.password(for: new) == "hunter2")
        #expect(vault.update(new, to: new, password: "hunter3"))
        #expect(vault.entries.count == 1)
        #expect(vault.password(for: new) == "hunter3")
    }

    @Test
    func search_matches_every_word_in_command_or_prompt() {
        let vault = PasswordVault(store: InMemoryPasswordStore())
        vault.save("a", for: PasswordEntryID(command: "ssh prod", prompt: "ethan@prod's password:"))
        vault.save("b", for: PasswordEntryID(command: "psql -h db1", prompt: "Password for user app:"))
        vault.save("c", for: PasswordEntryID(command: nil, prompt: "Enter passphrase for key '/k':"))
        #expect(vault.entries(matching: "").count == 3)
        #expect(vault.entries(matching: "PROD").map(\.id.command) == ["ssh prod"])
        #expect(vault.entries(matching: "password app").map(\.id.command) == ["psql -h db1"])
        #expect(vault.entries(matching: "passphrase").map(\.id.command) == [nil])
        #expect(vault.entries(matching: "nothing").isEmpty)
    }
}

/// Entries added for a command alone, and how a picked password is typed.
struct OnDemandPasswordTests {
    @Test
    func an_entry_without_a_prompt_is_on_demand_only() {
        let id = PasswordPromptIdentity.declaredEntryID(prompt: "", command: "sudo -i")
        #expect(id == PasswordEntryID(command: "sudo", prompt: ""))
        #expect(id.isOnDemandOnly)
        #expect(id.title == "sudo")
        #expect(!PasswordEntryID(command: "sudo", prompt: "Password:").isOnDemandOnly)
    }

    @Test
    func an_on_demand_account_cannot_collide_with_a_prompt_only_one() {
        let onDemand = PasswordEntryID(command: "deploy", prompt: "")
        let promptOnly = PasswordEntryID(command: nil, prompt: "deploy")
        #expect(onDemand.account != promptOnly.account)
        #expect(onDemand.account != PasswordEntryID(command: "deploy", prompt: "x").account)
    }

    @Test
    func the_line_mode_follows_canonical_and_echo() {
        let canonical = tcflag_t(ICANON)
        let echo = tcflag_t(ECHO)
        #expect(TerminalLineMode(localModes: canonical) == .password)
        #expect(TerminalLineMode(localModes: canonical | echo) == .echoing)
        #expect(TerminalLineMode(localModes: echo) == .raw)
        #expect(TerminalLineMode(localModes: 0) == .raw)
    }

    @Test
    func only_a_verified_read_gets_its_return() {
        #expect(OnDemandPasswordFill(mode: .password).isVerified)
        #expect(!OnDemandPasswordFill(mode: .raw).isVerified, "ssh, tmux and a shell's editor are left for the user to submit")
        #expect(!OnDemandPasswordFill(mode: .echoing).isVerified)
        #expect(!OnDemandPasswordFill(mode: nil).isVerified, "an unreadable tty is not a password read")
    }
}
