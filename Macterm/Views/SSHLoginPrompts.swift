import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "SSHLoginPrompts")

/// The questions that the login of a host's ssh master asks, shown as sheets
/// (design/005 step 2): a secure field for a password or a passphrase, or
/// Connect and Cancel for a host key and a confirmation. One sheet at a time;
/// the next waits.
///
/// A saved password for the login (filed under `ssh <destination>` and the
/// prompt line, as in v1) fills the answer only after a click on Use Saved
/// Password and the authentication of `PasswordAuthenticator`.
@MainActor
final class SSHLoginPrompts {
    static let shared = SSHLoginPrompts()

    struct Request: Equatable {
        var host: String
        var prompt: String
        var kind: Kind
        /// The master whose askpass asks.
        var sshPID: pid_t
        /// The ssh that runs the askpass: the master, or the ssh of a
        /// `ProxyJump` host under it. nil: not known.
        var askerPID: pid_t?

        /// Who asks. Two hosts of one login can ask the same text (a key
        /// passphrase), so a retry is the same prompt from the same ssh.
        var asker: Asker {
            Asker(sshPID: sshPID, askerPID: askerPID ?? sshPID)
        }
    }

    struct Asker: Hashable {
        var sshPID: pid_t
        var askerPID: pid_t
    }

    enum Kind: Equatable {
        case secret
        /// A line of "yes" or "no" (a new host key).
        case yesNo
        /// An exit status (`SSH_ASKPASS_PROMPT=confirm`).
        case confirm

        static func of(prompt: String, confirm: Bool) -> Kind {
            if confirm { return .confirm }
            return prompt.lowercased().contains("(yes/no") ? .yesNo : .secret
        }
    }

    enum Answer: Equatable {
        case text(String)
        case cancelled
    }

    private final class Pending {
        let request: Request
        let continuation: CheckedContinuation<Answer, Never>
        var sheet: (alert: NSAlert, window: NSWindow)?

        init(_ request: Request, _ continuation: CheckedContinuation<Answer, Never>) {
            self.request = request
            self.continuation = continuation
        }
    }

    private var queue: [Pending] = []
    private var current: Pending?
    /// The last secret prompt that each ssh got an answer to.
    private var answeredSecret: [Asker: String] = [:]

    func ask(_ request: Request) async -> Answer {
        await withCheckedContinuation { continuation in
            queue.append(Pending(request, continuation))
            presentNext()
        }
    }

    /// The master `pid` exited: its askpass is gone, so its questions are too.
    func cancel(sshPID pid: pid_t) {
        answeredSecret = answeredSecret.filter { $0.key.sshPID != pid }
        for pending in queue where pending.request.sshPID == pid {
            pending.continuation.resume(returning: .cancelled)
        }
        queue.removeAll { $0.request.sshPID == pid }
        guard let current, current.request.sshPID == pid else { return }
        if let sheet = current.sheet {
            sheet.window.endSheet(sheet.alert.window, returnCode: .abort)
        } else if NSApp.modalWindow != nil {
            NSApp.abortModal()
        }
    }

    // MARK: - Sheets

    private enum Button {
        static let primary = NSApplication.ModalResponse.alertFirstButtonReturn
        static let cancel = NSApplication.ModalResponse.alertSecondButtonReturn
        static let saved = NSApplication.ModalResponse.alertThirdButtonReturn
    }

    private func presentNext() {
        guard current == nil, !queue.isEmpty else { return }
        let pending = queue.removeFirst()
        current = pending
        let request = pending.request
        let savedID = savedEntry(for: request)

        let alert = NSAlert()
        alert.messageText = switch request.kind {
        case .secret: String(localized: "Log In to \(request.host)")
        case .yesNo,
             .confirm: String(localized: "Connect to \(request.host)?")
        }
        let prompt = Self.displayText(request.prompt)
        var fingerprint: NSTextField?
        switch request.kind {
        case .secret where Self.isRetry(request, answered: answeredSecret):
            alert.informativeText = Self.refusal(prompt) + "\n" + prompt
        case .yesNo:
            if let key = Self.hostKey(in: request.prompt) {
                alert.informativeText = String(
                    localized: "The key of this host is not known. Make sure that it is the key that you expect."
                )
                let label = NSTextField(labelWithString: "\(key.host)\n\(key.type) \(key.fingerprint)")
                label.font = TerminalFont.shared.nsFont(size: NSFont.smallSystemFontSize)
                label.isSelectable = true
                label.lineBreakMode = .byClipping
                label.sizeToFit()
                fingerprint = label
            } else {
                alert.informativeText = Self.withoutQuestion(prompt)
            }
        default:
            alert.informativeText = prompt
        }
        alert.accessoryView = fingerprint
        alert.addButton(withTitle: request.kind == .secret
            ? String(localized: "Log In")
            : String(localized: "Connect", comment: "The button that accepts an ssh question, such as a new host key."))
        alert.addButton(withTitle: String(localized: "Cancel"))
        var field: NSSecureTextField?
        if request.kind == .secret {
            let secure = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            alert.accessoryView = secure
            alert.window.initialFirstResponder = secure
            field = secure
            if savedID != nil { alert.addButton(withTitle: String(localized: "Use Saved Password")) }
        }

        // A terminal window: the key window can be the quick terminal, a
        // desktop widget or a popover, which a sheet does not suit.
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap(\.self) + NSApp.windows.filter(\.isVisible)
        guard let window = candidates.first(where: { AppDelegate.isTerminalWindowCandidate($0) })
        else {
            NSApp.activate()
            finish(pending, response: alert.runModal(), field: field, savedID: savedID)
            return
        }
        pending.sheet = (alert, window)
        NSApp.activate()
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.finish(pending, response: response, field: field, savedID: savedID)
        }
    }

    private func finish(_ pending: Pending, response: NSApplication.ModalResponse, field: NSSecureTextField?, savedID: PasswordEntryID?) {
        let request = pending.request
        if request.kind == .secret, response == Button.primary {
            answeredSecret[request.asker] = request.prompt
        }
        let answer: Answer? = switch response {
        case Button.primary: .text(request.kind == .secret ? field?.stringValue ?? "" : request.kind == .yesNo ? "yes" : "")
        case Button.saved: nil
        default: .cancelled
        }
        if let answer {
            settle(pending, answer)
            return
        }
        // Use Saved Password: the click is the request; the authentication
        // is the gate. A refusal shows the question again.
        guard let savedID else { return settle(pending, .cancelled) }
        Task { @MainActor in
            let allowed = await PasswordAuthenticator.shared.authorize(
                reason: String(
                    localized: "autofill the password for “\(request.host)”",
                    comment: "Touch ID reason. macOS shows it after “Macterm is trying to”."
                )
            )
            if allowed, let password = PasswordVault.shared.password(for: savedID) {
                answeredSecret[request.asker] = request.prompt
                settle(pending, .text(password))
            } else if kill(request.sshPID, 0) == 0 {
                current = nil
                queue.insert(pending, at: 0)
                presentNext()
            } else {
                // The master exited while Touch ID was up.
                settle(pending, .cancelled)
            }
        }
    }

    private func settle(_ pending: Pending, _ answer: Answer) {
        let result = answer == .cancelled ? "cancelled" : "answered"
        logger.info("ssh prompt for host=\(pending.request.host, privacy: .public): \(result, privacy: .public)")
        pending.continuation.resume(returning: answer)
        if current === pending { current = nil }
        presentNext()
    }

    /// v1 files a remote project's login under `ssh <destination>` and the
    /// prompt line, so a password saved at a v1 pane's login fills here too.
    private func savedEntry(for request: Request) -> PasswordEntryID? {
        guard Preferences.shared.passwordManagerEnabled else { return nil }
        let id = PasswordEntryID(
            command: "ssh \(request.host)",
            prompt: request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return PasswordVault.shared.contains(id) ? id : nil
    }

    /// The same secret prompt again, from the same ssh, after an answer:
    /// ssh refused that answer.
    static func isRetry(_ request: Request, answered: [Asker: String]) -> Bool {
        request.kind == .secret && answered[request.asker] == request.prompt
    }

    /// What a refused answer was, named only when the prompt says it.
    static func refusal(_ prompt: String) -> String {
        let lowered = prompt.lowercased()
        if lowered.contains("passphrase") { return String(localized: "The passphrase is incorrect.") }
        if lowered.contains("password") { return String(localized: "The password is incorrect.") }
        return String(localized: "The answer is incorrect.")
    }

    /// The host, key type and fingerprint of ssh's question about a new host
    /// key ("The authenticity of host 'box (1.2.3.4)' can't be established."
    /// and "ED25519 key fingerprint is SHA256:…." or, from OpenSSH 10.5,
    /// "ED25519 key fingerprint is: SHA256:…"), or nil when either line
    /// is missing. With `ProxyJump` the key can be the jump host's, so the
    /// sheet shows the host that ssh names.
    static func hostKey(in prompt: String) -> HostKey? {
        let opening = "The authenticity of host '"
        var host: String?
        var key: (type: String, fingerprint: String)?
        for line in prompt.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix(opening) {
                let rest = text.dropFirst(opening.count)
                if let end = rest.firstIndex(of: "'"), end > rest.startIndex { host = String(rest[..<end]) }
                continue
            }
            let words = text.split(separator: " ")
            // OpenSSH 10.5 and later writes "is:", older releases "is".
            guard words.count == 5, words[1 ... 2] == ["key", "fingerprint"],
                  words[3] == "is" || words[3] == "is:"
            else { continue }
            var fingerprint = String(words[4])
            if fingerprint.hasSuffix(".") { fingerprint.removeLast() }
            guard fingerprint.contains(":") else { continue }
            key = (String(words[0]), fingerprint)
        }
        guard let host, let key else { return nil }
        return HostKey(host: host, type: key.type, fingerprint: key.fingerprint)
    }

    struct HostKey: Equatable {
        var host: String
        var type: String
        var fingerprint: String
    }

    /// ssh's text without its last line when that line asks "(yes/no…)?":
    /// the buttons ask it.
    static func withoutQuestion(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1, lines.last?.lowercased().contains("(yes/no") == true { lines.removeLast() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ssh's prompt with its control characters removed, and capped.
    static func displayText(_ prompt: String) -> String {
        let scalars = prompt.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars).prefix(2048)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
