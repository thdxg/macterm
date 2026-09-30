import AppKit
@testable import Macterm
import Testing

/// The monitor's state machine, driven without a surface: every read of the
/// tty, screen and process table comes through `Probes`, the bubble is a
/// recording double, and the clock is a variable.
@MainActor
struct PasswordPromptMonitorStateTests {
    /// The world as the probes report it.
    @MainActor
    final class World {
        var atPrompt = false
        /// The tty has left line mode (a shell's editor, ssh relaying a session).
        var nonCanonical = false
        var screen = ""
        var asker = PasswordAsker.program(path: "/usr/bin/ssh", command: "/usr/bin/ssh prod", isProtected: true)
        var localShellInForeground = true
        var offerToSave = true
        var authorized = true
        var now = Date(timeIntervalSinceReferenceDate: 1000)
    }

    @MainActor
    final class RecordingBubble: PasswordBubble {
        var presented = 0
        override func present(at _: NSRect, in _: NSView) {
            presented += 1
        }

        override func tearDown() {}
    }

    @MainActor
    struct Harness {
        let world = World()
        let vault: PasswordVault
        let monitor: PasswordPromptMonitor
        let pane: Pane
        let view: GhosttyTerminalNSView
        let bubble = RecordingBubble()

        init(store: PasswordStoring = InMemoryPasswordStore()) {
            let world = world
            let bubble = bubble
            vault = PasswordVault(store: store)
            var probes = PasswordPromptMonitor.Probes()
            probes.isReadingPassword = { _ in world.atPrompt }
            probes.isNonCanonical = { _ in world.nonCanonical }
            probes.screenText = { _ in world.screen }
            probes.transcript = { _ in world.screen }
            probes.asker = { _ in world.asker }
            probes.foregroundIsLocalShell = { _ in world.localShellInForeground }
            probes.anchor = { _ in NSRect(x: 0, y: 0, width: 10, height: 10) }
            probes.makeBubble = { bubble }
            probes.autoSecureInput = { false }
            probes.offerToSave = { world.offerToSave }
            probes.authorize = { _ in world.authorized }
            probes.focusedView = { nil }
            probes.isAppActive = { false }
            monitor = PasswordPromptMonitor(vault: vault, now: { world.now }, probes: probes)
            pane = Pane(projectPath: "/tmp", projectID: UUID())
            view = pane.ensureNSView()
        }

        var state: ControlPasswordState { monitor.state(for: view) }

        func advance(_ seconds: TimeInterval) {
            world.now = world.now.addingTimeInterval(seconds)
            monitor.observe(view)
        }

        /// A prompt appears on screen and the tty goes to password mode.
        func prompt(_ line: String) {
            world.atPrompt = true
            world.screen += "\(line)\n"
            monitor.observe(view)
        }

        func type(_ text: String) {
            for character in text {
                monitor.viewDidType(view, input: .text(String(character)))
            }
        }

        func submit() {
            monitor.viewDidType(view, input: .submit)
        }

        /// The program answered: the prompt ends and `output` is printed.
        func respond(_ output: String, promptAgain: String? = nil) {
            world.atPrompt = promptAgain != nil
            world.screen += "\(output)\n"
            if let promptAgain { world.screen += "\(promptAgain)\n" }
            advance(PasswordSubmissionJudge.settleDelay + 0.1)
        }

        func keyEvent(_ characters: String, keyCode: UInt16) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            )!
        }

        var returnKey: NSEvent { keyEvent("\r", keyCode: 36) }
        var escapeKey: NSEvent { keyEvent("\u{1b}", keyCode: 53) }
    }

    private let login = "ethan@prod's password:"
    private var entry: PasswordEntryID { PasswordEntryID(command: "/usr/bin/ssh prod", prompt: login) }

    @Test
    func a_sighting_must_hold_before_it_is_a_prompt() {
        let h = Harness()
        h.prompt(login)
        #expect(h.state.phase == "sighted")
        h.advance(0.1)
        #expect(h.state.phase == "sighted")
        h.advance(0.15)
        #expect(h.state.phase == "prompting")
        #expect(h.state.prompt == login)
        #expect(h.state.command == "/usr/bin/ssh prod")
        #expect(h.state.bubble == nil, "nothing saved: no bubble")
    }

    @Test
    func a_flash_of_echo_off_is_not_a_prompt() {
        let h = Harness()
        h.prompt("reading terminal reply")
        h.world.atPrompt = false
        h.advance(0.05)
        #expect(h.state.phase == "idle")
    }

    @Test
    func typing_at_a_sighting_confirms_it_at_once() {
        let h = Harness()
        h.prompt(login)
        h.type("h")
        #expect(h.state.phase == "prompting")
    }

    @Test
    func a_working_password_is_offered_then_saved_then_autofillable() async {
        let h = Harness()
        h.prompt(login)
        h.type("hunter2")
        h.submit()
        #expect(h.state.phase == "verifying")
        h.respond("Last login: Sat")
        #expect(h.state.phase == "idle")
        #expect(h.state.bubble == "save")

        #expect(h.monitor.answer(.accept, in: h.view))
        #expect(h.vault.password(for: entry) == "hunter2")
        #expect(h.state.bubble == nil)

        h.prompt(login)
        h.advance(0.3)
        #expect(h.state.saved)
        #expect(h.state.bubble == "autofill")
        #expect(h.monitor.answer(.autofill, in: h.view))
        // The authorization is awaited on the main actor; let it land.
        await Task.yield()
        for _ in 0 ..< 20 where h.state.phase != "verifying" {
            await Task.yield()
        }
        #expect(h.state.phase == "verifying")
    }

    @Test
    func a_rejected_password_is_not_offered() {
        let h = Harness()
        h.prompt(login)
        h.type("wrong")
        h.submit()
        h.respond("Permission denied, please try again.", promptAgain: login)
        #expect(h.state.bubble == nil)
        #expect(h.state.phase == "sighted", "the re-prompt is a fresh sighting")
    }

    @Test
    func line_editing_and_a_pasted_newline_are_mirrored() {
        let h = Harness()
        h.prompt(login)
        h.type("hunter2x")
        h.monitor.viewDidType(h.view, input: .backspace)
        h.monitor.viewDidSendText(h.view, text: "\n")
        h.respond("welcome")
        #expect(h.monitor.answer(.accept, in: h.view))
        #expect(h.vault.password(for: entry) == "hunter2")
    }

    @Test
    func an_unmirrorable_key_means_no_offer() {
        let h = Harness()
        h.prompt(login)
        h.type("hun")
        h.monitor.viewDidType(h.view, input: .unknown)
        h.type("ter2")
        h.submit()
        h.respond("welcome")
        #expect(h.state.bubble == nil)
    }

    @Test
    func offers_queue_for_a_command_that_asks_twice() {
        let h = Harness()
        h.prompt("ethan@bastion's password:")
        h.type("one")
        h.submit()
        h.respond("", promptAgain: login)
        // The first offer waits while the second prompt is up.
        #expect(h.state.bubble == nil)
        h.advance(0.3)
        h.type("two")
        h.submit()
        h.respond("welcome")
        #expect(h.state.bubble == "save")
        #expect(h.monitor.answer(.accept, in: h.view))
        #expect(h.state.bubble == "save", "the second offer follows the first")
        #expect(h.monitor.answer(.accept, in: h.view))
        #expect(h.state.bubble == nil)
        #expect(h.vault.password(for: PasswordEntryID(command: "/usr/bin/ssh prod", prompt: "ethan@bastion's password:")) == "one")
        #expect(h.vault.password(for: entry) == "two")
    }

    @Test
    func return_and_escape_belong_to_the_bubble_until_something_is_typed() {
        let h = Harness()
        h.vault.save("hunter2", for: entry)
        h.prompt(login)
        h.advance(0.3)
        #expect(h.state.bubble == "autofill")
        #expect(h.bubble.isShown)
        // Escape dismisses.
        #expect(h.monitor.viewWillSendKey(h.view, event: h.escapeKey))
        #expect(h.state.bubble == nil)
        #expect(h.state.phase == "prompting", "the prompt itself is untouched")

        // A fresh prompt, a typed character, then Return goes to the terminal.
        h.world.atPrompt = false
        h.advance(0.1)
        h.prompt(login)
        h.advance(0.3)
        #expect(h.state.bubble == "autofill")
        h.type("x")
        #expect(!h.monitor.viewWillSendKey(h.view, event: h.returnKey))
        #expect(!h.monitor.viewWillSendKey(h.view, event: h.escapeKey))
    }

    @Test
    func a_bare_return_keeps_an_offer_and_a_command_run_by_the_shell_drops_it() {
        let h = Harness()
        h.prompt(login)
        h.type("hunter2")
        h.submit()
        h.respond("welcome")
        #expect(h.state.bubble == "save")
        // Return under the bubble is Save — so a bare Return at the shell is
        // modeled as the terminal's: the bubble consumed nothing because
        // `typedSinceBubble` is false only for the bubble; here we type
        // Return through the terminal path after the bubble was hidden.
        h.monitor.viewDidType(h.view, input: .submit)
        #expect(h.state.bubble == "save", "a bare Return keeps the offer")
        // Inside ssh: the shell isn't in the foreground, so a command there
        // keeps the offer too.
        h.world.localShellInForeground = false
        h.type("ls")
        h.submit()
        #expect(h.state.bubble == "save")
        // Back at the local shell, a typed command drops it.
        h.world.localShellInForeground = true
        h.type("ls")
        h.submit()
        #expect(h.state.bubble == nil)
    }

    @Test
    func an_offer_expires() {
        let h = Harness()
        h.prompt(login)
        h.type("hunter2")
        h.submit()
        h.respond("welcome")
        #expect(h.state.bubble == "save")
        h.world.now = h.world.now.addingTimeInterval(PasswordPromptMonitor.offerLifetime + 1)
        // Expiry is applied on the poll tick, which `observe` doesn't run;
        // the offer is still held in memory until then.
        #expect(h.state.bubble == "save")
    }

    @Test
    func a_failed_keychain_write_keeps_the_offer_with_the_reason() {
        let h = Harness(store: FailingPasswordStore())
        h.prompt(login)
        h.type("hunter2")
        h.submit()
        h.respond("welcome")
        #expect(h.state.bubble == "save")
        #expect(h.monitor.answer(.accept, in: h.view))
        #expect(h.state.bubble == "save", "the offer — and the secret — stay on the table")
        #expect(h.monitor.answer(.dismiss, in: h.view))
        #expect(h.state.bubble == nil)
    }

    @Test
    func typing_at_a_re_prompt_settles_the_pending_verdict_and_captures_everything() {
        let h = Harness()
        h.prompt(login)
        h.type("wrong")
        h.submit()
        // The rejection and re-prompt arrive, and the user retypes within
        // the settle window.
        h.world.screen += "Permission denied, please try again.\n\(login)\n"
        h.world.atPrompt = true
        h.world.now = h.world.now.addingTimeInterval(0.05)
        h.type("hunter2")
        h.submit()
        h.respond("welcome")
        #expect(h.state.bubble == "save")
        #expect(h.monitor.answer(.accept, in: h.view))
        #expect(h.vault.password(for: entry) == "hunter2", "not missing its first characters")
    }

    @Test
    func a_refused_autofill_is_reported_on_the_next_prompt_and_a_retype_offers_an_update() async {
        let h = Harness()
        h.vault.save("stale", for: entry)
        h.prompt(login)
        h.advance(0.3)
        #expect(h.monitor.answer(.autofill, in: h.view))
        for _ in 0 ..< 20 where h.state.phase != "verifying" {
            await Task.yield()
        }
        h.respond("Permission denied, please try again.", promptAgain: login)
        h.advance(0.3)
        #expect(h.state.bubble == "rejected")
        h.type("fresh")
        h.submit()
        h.respond("welcome")
        #expect(h.state.bubble == "update")
        #expect(h.monitor.answer(.accept, in: h.view))
        #expect(h.vault.password(for: entry) == "fresh")
    }

    @Test
    func one_time_codes_and_disabled_offers_are_never_offered() {
        let h = Harness()
        h.prompt("Verification code:")
        h.type("123456")
        h.submit()
        h.respond("welcome")
        #expect(h.state.bubble == nil)

        h.world.offerToSave = false
        h.prompt(login)
        h.type("hunter2")
        h.submit()
        h.respond("welcome")
        #expect(h.state.bubble == nil)
    }

    @Test
    func a_nonzero_exit_without_a_rejection_still_offers() {
        let h = Harness()
        h.prompt("Password:")
        h.type("hunter2")
        h.submit()
        h.world.atPrompt = false
        h.monitor.viewDidFinishCommand(h.view, exitCode: 1)
        #expect(h.state.bubble == "save")
    }

    @Test
    func a_remote_projects_login_is_captured_and_offered() {
        // The pane's ssh reads the surface's own pty, so it has the line and
        // has left the read by the time `keyDown` reports the Return.
        let h = Harness()
        h.prompt("demo@localhost's password:")
        h.type("hunter2")
        h.world.atPrompt = false
        h.submit()
        #expect(h.state.phase == "verifying")
        // Logged in: ssh relays the session in raw mode, and zmx repaints the
        // screen from the top — no line is ever drawn below the prompt.
        h.world.nonCanonical = true
        h.world.screen = "\n\n\n"
        h.advance(PasswordSubmissionJudge.settleDelay + 0.1)
        #expect(h.state.phase == "idle")
        #expect(h.state.bubble == "save")
        #expect(h.monitor.answer(.accept, in: h.view))
        #expect(h.vault.password(for: PasswordEntryID(command: "/usr/bin/ssh prod", prompt: "demo@localhost's password:")) == "hunter2")
    }

    @Test
    func only_a_line_end_is_credited_to_a_read_that_already_ended() {
        let h = Harness()
        h.prompt(login)
        h.type("hunter2")
        h.world.atPrompt = false
        // A character typed after the read ended went to whatever reads now.
        h.type("x")
        #expect(h.state.phase == "idle")
        h.submit()
        #expect(h.state.phase == "idle", "the Return belongs to the program now")
    }

    @Test
    func forgetting_a_view_drops_everything() {
        let h = Harness()
        h.prompt(login)
        h.type("hunter2")
        h.submit()
        h.respond("welcome")
        #expect(h.state.bubble == "save")
        h.monitor.forget(h.view)
        #expect(h.state.phase == "idle")
        #expect(h.state.bubble == nil)
    }
}

/// A store whose writes fail, for the keychain-error paths.
final class FailingPasswordStore: PasswordStoring, @unchecked Sendable {
    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "The keychain is locked." }
    }

    @Test
    func an_unreadable_asker_holds_the_prompt_unconfirmed() {
        let h = Harness()
        h.world.asker = .unknown
        h.prompt(login)
        h.advance(0.3)
        #expect(h.state.phase == "sighted", "no entry to match it against")
        h.world.asker = .program(path: "/usr/bin/ssh", command: "/usr/bin/ssh prod", isProtected: true)
        h.advance(0.15)
        #expect(h.state.phase == "prompting")
        #expect(h.state.command == "/usr/bin/ssh prod")
    }

    @Test
    func keys_typed_while_the_asker_is_unreadable_offer_nothing() {
        let h = Harness()
        h.world.asker = .unknown
        h.prompt(login)
        h.type("hun")
        #expect(h.state.phase == "sighted")
        h.world.asker = .program(path: "/usr/bin/ssh", command: "/usr/bin/ssh prod", isProtected: true)
        h.type("ter2")
        #expect(h.state.phase == "prompting")
        h.submit()
        h.respond("welcome")
        #expect(h.state.bubble == nil, "the capture is missing keys the program received")
    }

    @Test
    func a_fake_sudo_is_not_offered_the_real_sudo_password() {
        let h = Harness()
        #expect(h.vault.save("login-password", for: PasswordEntryID(command: "sudo", prompt: "Password:")))
        h.world.asker = .program(path: "/Users/e/bin/sudo", command: "/Users/e/bin/sudo ls", isProtected: false)
        h.prompt("Password:")
        h.advance(0.3)
        #expect(h.state.phase == "prompting")
        #expect(h.state.command == "/Users/e/bin/sudo ls")
        #expect(h.state.bubble == nil, "no autofill for another program's entry")
    }

    func list() throws -> [SavedPassword] {
        []
    }

    func password(for _: PasswordEntryID) throws -> String? {
        nil
    }

    func save(_: String, for _: PasswordEntryID) throws {
        throw Failure()
    }

    func delete(_: PasswordEntryID) throws {}
}
