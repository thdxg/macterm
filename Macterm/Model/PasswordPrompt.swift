import Foundation

/// What a saved password is filed under: the command that asked for it plus
/// the prompt line it printed. A command alone is not enough, because one
/// command can ask more than once (`ssh -J bastion prod` asks for the
/// bastion's password and then prod's); the prompt line tells them apart.
///
/// `command` is nil for a prompt that names its own secret regardless of who
/// asks — a key passphrase belongs to the key file, not to `ssh prod` or
/// `ssh-add`. Every other command is matched exactly as the process table
/// reports it, except `sudo`, which is filed under the bare word: its password
/// is the user's login password whatever it runs, so one entry covers every
/// `sudo …`.
struct PasswordEntryID: Hashable, Codable {
    let command: String?
    let prompt: String

    /// The Keychain account string. Readable in Keychain Access, deterministic
    /// for a lookup, and never parsed back — the entry's metadata is.
    var account: String {
        if let command { "\(command) — \(prompt)" } else { prompt }
    }

    /// What a person reads as "which one": the command, or the prompt when
    /// the entry is command-independent.
    var title: String { displayCommand ?? prompt }

    /// The command as shown: the process table reports the program the
    /// command resolved to (`python3` runs `/opt/homebrew/…/Python`), so a
    /// path in the program position is shortened to its name. Matching still
    /// uses the exact `command`.
    var displayCommand: String? {
        guard let command else { return nil }
        let parts = command.split(separator: " ", maxSplits: 1)
        guard let program = parts.first, program.contains("/") else { return command }
        let name = (String(program) as NSString).lastPathComponent
        return parts.count > 1 ? "\(name) \(parts[1])" : name
    }
}

enum PasswordPromptIdentity {
    /// Longest prompt line kept. A real prompt is one short line; anything
    /// longer is output the program printed without a newline, and truncating
    /// keeps a runaway line out of the Keychain.
    static let maxPromptLength = 200

    /// The prompt the program printed: the last non-empty line of the
    /// viewport. At a password prompt the cursor sits at the end of that line
    /// and nothing below it has been drawn yet — echo is off, so the typed
    /// password never appears. Whitespace runs collapse so a re-rendered
    /// prompt matches its earlier self.
    static func promptLine(fromViewport text: String) -> String? {
        let line = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reversed()
            .map { normalize(String($0)) }
            .first { !$0.isEmpty }
        guard let line else { return nil }
        return String(line.prefix(maxPromptLength))
    }

    static func normalize(_ line: String) -> String {
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The entry a prompt files under (see `PasswordEntryID`).
    static func entryID(prompt: String, command: String?) -> PasswordEntryID {
        if isKeyPassphrase(prompt) {
            return PasswordEntryID(command: nil, prompt: prompt)
        }
        guard let command = command.map(normalize), !command.isEmpty else {
            return PasswordEntryID(command: nil, prompt: prompt)
        }
        if isSudo(command) {
            return PasswordEntryID(command: "sudo", prompt: prompt)
        }
        return PasswordEntryID(command: command, prompt: prompt)
    }

    /// `ssh`/`ssh-add`/`ssh-keygen`: `Enter passphrase for key '/path':` and
    /// `Enter passphrase for /path:`.
    static func isKeyPassphrase(_ prompt: String) -> Bool {
        prompt.range(of: #"^Enter passphrase for (key )?\S"#, options: .regularExpression) != nil
    }

    /// A prompt for a code that is only good once — a 2FA verification code,
    /// an authenticator or hardware-token response. Saving one would autofill
    /// a stale code next time, so no save is ever offered for these.
    static func isOneTimeCode(_ prompt: String) -> Bool {
        let lower = prompt.lowercased()
        return ["verification code", "one-time", "one time", "otp", "2fa", "two-factor", "authenticator", "token:", "passcode"]
            .contains { lower.contains($0) }
    }

    static func isSudo(_ command: String) -> Bool {
        let first = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        return (first as NSString).lastPathComponent == "sudo"
    }

    /// What a remote project's own pane is running when its ssh asks for a
    /// password: Macterm's spawn wrapper is an implementation detail, so the
    /// entry is filed under the connection it makes.
    static func remoteCommand(user: String?, host: String) -> String {
        if let user, !user.isEmpty { "ssh \(user)@\(host)" } else { "ssh \(host)" }
    }
}

/// One key as the password prompt's line discipline will see it. Built from
/// the key event before it reaches libghostty (`GhosttyTerminalNSView`), and
/// from a paste's resolved text.
enum PasswordKeyInput: Equatable {
    case text(String)
    case backspace
    /// ⌃U — the tty's VKILL: erase the whole line.
    case killLine
    /// ⌃W — VWERASE: erase back over one word.
    case killWord
    case submit
    /// ⌃C / ⌃D: the program abandons the read.
    case cancel
    /// Escape. Like `unknown` for the line (the tty inserts it literally),
    /// kept distinct so a visible bubble can take it as Dismiss.
    case escape
    /// A key whose effect on the line can't be mirrored (arrows, escape,
    /// forward-delete, other control chords). The capture can no longer vouch
    /// for what the program received, so it will not offer to save it.
    case unknown
}

/// Mirrors the canonical-mode line editing a password read goes through, so
/// the captured text is what the program received rather than the raw key
/// sequence. The defaults every macOS and Linux tty ships with: DEL/⌃H erase
/// a character, ⌃U the line, ⌃W a word; Return ends the line.
struct PasswordLineCapture: Equatable {
    enum Outcome: Equatable {
        case editing
        case submitted(String)
        case cancelled
    }

    private(set) var buffer = ""
    /// Set once a key the capture can't mirror was typed.
    private(set) var isTainted = false

    mutating func apply(_ input: PasswordKeyInput) -> Outcome {
        switch input {
        case let .text(text):
            // A paste may carry its own line end; everything up to it is the
            // password, and the newline submits it.
            if let newline = text.firstIndex(where: \.isNewline) {
                buffer += text[..<newline]
                return submit()
            }
            buffer += text
        case .backspace:
            if !buffer.isEmpty { buffer.removeLast() }
        case .killLine:
            buffer = ""
        case .killWord:
            while buffer.last?.isWhitespace == true {
                buffer.removeLast()
            }
            while let last = buffer.last, !last.isWhitespace {
                buffer.removeLast()
            }
        case .submit:
            return submit()
        case .cancel:
            buffer = ""
            return .cancelled
        case .unknown,
             .escape:
            isTainted = true
        }
        return .editing
    }

    private mutating func submit() -> Outcome {
        let typed = buffer
        buffer = ""
        // A tainted or empty line is still submitted — the program received
        // it — but there is nothing trustworthy to offer.
        return .submitted(isTainted ? "" : typed)
    }
}

/// Decides, after a password was submitted, whether it worked. A rejection
/// is visible: every program prints one ("Permission denied, please try
/// again.", "Sorry, try again.") right after the prompt. Success is mostly
/// its absence, so the rules below call success only on positive evidence —
/// the read ended and something else happened — and give up rather than
/// guess once `timeout` passes.
///
/// Two things deliberately are NOT evidence of a rejection. The command's
/// exit code: it judges the command, not the password (`sudo grep -q`,
/// `sudo test -f`, `ssh host cmd` exit nonzero with the password accepted).
/// And the identical prompt appearing again without a failure line: git over
/// HTTPS asks the same `Password for 'https://…':` once per connection, and
/// a push opens two, so the repeat is the next read, not a retry.
struct PasswordSubmissionJudge {
    enum Verdict: Equatable {
        case pending
        case succeeded
        case failed
        /// No evidence either way in time. Nothing is saved.
        case undetermined
    }

    /// Echo stays off for a moment after Return while the program reads the
    /// line; a prompt still showing inside this window is the same read.
    static let settleDelay: TimeInterval = 0.3
    static let timeout: TimeInterval = 12

    /// How many lines after the prompt a failure message is looked for. Every
    /// program prints its rejection on the line right after the prompt; a
    /// banner or MOTD further down that happens to say "denied" is not one.
    static let failureWindow = 3

    /// Lowercased substrings of the lines auth failures print: ssh
    /// ("Permission denied, please try again."), sudo ("Sorry, try again.",
    /// "incorrect password attempts"), su, login, psql/mysql, gpg and friends.
    static let failureMarkers = [
        "denied",
        "incorrect",
        "try again",
        "authentication fail",
        "authentication error",
        "invalid password",
        "wrong password",
        "bad password",
        "login failed",
        "bad passphrase",
        "connection closed",
        "connection reset",
    ]

    let submittedPrompt: String
    let submittedAt: Date

    struct Observation {
        let now: Date
        /// The pane's tty is at a password read right now.
        let atPasswordPrompt: Bool
        /// The prompt line showing now (meaningful when `atPasswordPrompt`).
        let currentPrompt: String?
        /// Non-empty lines drawn below the submitted prompt since Return.
        let outputAfterPrompt: [String]
        /// The exit code shell integration reported for the command, if the
        /// command has finished (OSC 133;D).
        let exitCode: Int32?
    }

    func evaluate(_ o: Observation) -> Verdict {
        let elapsed = o.now.timeIntervalSince(submittedAt)
        if Self.containsFailure(o.outputAfterPrompt) { return .failed }
        // A prompt up again past the settle window is the next read — the
        // next hop's password, or the same question asked afresh — and the
        // previous one was accepted, since no rejection was printed.
        if o.atPasswordPrompt, elapsed >= Self.settleDelay { return .succeeded }
        // The command ended without printing a rejection: the read was
        // accepted, whatever the command then made of its work.
        if let code = o.exitCode, code >= 0 { return .succeeded }
        if !o.atPasswordPrompt, elapsed >= Self.settleDelay, !o.outputAfterPrompt.isEmpty {
            return .succeeded
        }
        return elapsed >= Self.timeout ? .undetermined : .pending
    }

    /// The verdict as of now, without waiting out the settle window — for
    /// when the user has started typing at a prompt, which says the read this
    /// submission fed is over.
    func settle(_ o: Observation) -> Verdict {
        let forced = Observation(
            now: max(o.now, submittedAt.addingTimeInterval(Self.settleDelay)),
            atPasswordPrompt: o.atPasswordPrompt,
            currentPrompt: o.currentPrompt,
            outputAfterPrompt: o.outputAfterPrompt,
            exitCode: o.exitCode
        )
        let verdict = evaluate(forced)
        return verdict == .pending ? .succeeded : verdict
    }

    static func containsFailure(_ lines: [String]) -> Bool {
        lines.prefix(failureWindow).contains { line in
            let lower = line.lowercased()
            return failureMarkers.contains { lower.contains($0) }
        }
    }

    /// Where a transcript (the screen with its scrollback) ends right now:
    /// one past its last non-empty line. Taken at Return, it marks the
    /// submission; what the program prints lands after it. Non-empty rather
    /// than the raw count, because the viewport pads with blank rows that
    /// output fills in without the count changing.
    static func transcriptEnd(_ text: String) -> Int {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let last = lines.lastIndex(where: { !$0.allSatisfy(\.isWhitespace) }) else { return 0 }
        return last + 1
    }

    /// The non-empty lines the transcript gained since `end`
    /// (`transcriptEnd` at submission). Searching for the prompt line instead
    /// would be wrong exactly when it matters: a rejection re-prompts with the
    /// same line, and "after its last occurrence" is then nothing at all.
    static func output(since end: Int, in text: String) -> [String] {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { PasswordPromptIdentity.normalize(String($0)) }
        guard end < lines.count else { return [] }
        return lines[end...].filter { !$0.isEmpty }
    }
}
