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

    @Test
    func entry_is_the_command_plus_the_prompt() {
        let id = PasswordPromptIdentity.entryID(prompt: "ethan@prod's password:", command: "ssh  prod")
        #expect(id == PasswordEntryID(command: "ssh prod", prompt: "ethan@prod's password:"))
        #expect(id.account == "ssh prod — ethan@prod's password:")
        #expect(id.title == "ssh prod")
    }

    @Test
    func a_resolved_program_path_is_shown_by_name() {
        let id = PasswordEntryID(command: "/opt/homebrew/Cellar/python@3.14/Python /tmp/login.py", prompt: "Password:")
        #expect(id.displayCommand == "Python /tmp/login.py")
        #expect(PasswordEntryID(command: "/usr/bin/sudo", prompt: "Password:").displayCommand == "sudo")
        #expect(PasswordEntryID(command: "ssh prod", prompt: "p:").displayCommand == "ssh prod")
        #expect(PasswordEntryID(command: nil, prompt: "p:").title == "p:")
    }

    @Test
    func one_command_asking_twice_files_two_entries() {
        let bastion = PasswordPromptIdentity.entryID(prompt: "ethan@bastion's password:", command: "ssh -J bastion prod")
        let prod = PasswordPromptIdentity.entryID(prompt: "ethan@prod's password:", command: "ssh -J bastion prod")
        #expect(bastion != prod)
    }

    @Test
    func sudo_files_under_the_bare_word() {
        let update = PasswordPromptIdentity.entryID(prompt: "Password:", command: "sudo apt update")
        let upgrade = PasswordPromptIdentity.entryID(prompt: "Password:", command: "/usr/bin/sudo -E make install")
        #expect(update == PasswordEntryID(command: "sudo", prompt: "Password:"))
        #expect(update == upgrade)
        // A command that merely mentions sudo is not sudo.
        #expect(PasswordPromptIdentity.entryID(prompt: "Password:", command: "man sudo").command == "man sudo")
    }

    @Test
    func key_passphrase_belongs_to_the_key_not_the_command() {
        let ssh = PasswordPromptIdentity.entryID(prompt: "Enter passphrase for key '/Users/e/.ssh/id_ed25519':", command: "ssh prod")
        let add = PasswordPromptIdentity.entryID(prompt: "Enter passphrase for key '/Users/e/.ssh/id_ed25519':", command: "ssh-add")
        #expect(ssh.command == nil)
        #expect(ssh == add)
        #expect(PasswordPromptIdentity.isKeyPassphrase("Enter passphrase for /Users/e/.ssh/id_rsa:"))
        #expect(!PasswordPromptIdentity.isKeyPassphrase("Enter password:"))
    }

    @Test
    func no_command_files_by_prompt_alone() {
        // A shell builtin (`read -s`) leaves no foreground command.
        #expect(PasswordPromptIdentity.entryID(prompt: "Vault password:", command: nil).command == nil)
        #expect(PasswordPromptIdentity.entryID(prompt: "Vault password:", command: "  ").command == nil)
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
    func the_same_prompt_again_is_a_failure() {
        #expect(observe(after: 2, atPrompt: true, prompt: "ethan@prod's password:") == .failed)
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
    func exit_codes_decide() {
        #expect(observe(after: 0.1, exit: 0) == .succeeded)
        #expect(observe(after: 0.1, output: ["Welcome"], exit: 1) == .failed)
        // -1: shell integration couldn't read the status; not a verdict.
        #expect(observe(after: 0.1, exit: -1) == .pending)
    }

    @Test
    func silence_times_out_undetermined() {
        #expect(observe(after: 5) == .pending)
        #expect(observe(after: PasswordSubmissionJudge.timeout) == .undetermined)
    }

    @Test
    func output_is_read_below_the_last_copy_of_the_prompt() {
        let screen = """
        ~ $ ssh prod
        ethan@prod's password:
        Permission denied, please try again.
        ethan@prod's password:
        Last login: Sat

        """
        #expect(PasswordSubmissionJudge.output(after: "ethan@prod's password:", inViewport: screen) == ["Last login: Sat"])
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
