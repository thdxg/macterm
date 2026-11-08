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

    func ask(_ request: Request) async -> Answer {
        await withCheckedContinuation { continuation in
            queue.append(Pending(request, continuation))
            presentNext()
        }
    }

    /// The master `pid` exited: its askpass is gone, so its questions are too.
    func cancel(sshPID pid: pid_t) {
        for pending in queue where pending.request.sshPID == pid {
            pending.continuation.resume(returning: .cancelled)
        }
        queue.removeAll { $0.request.sshPID == pid }
        if let current, current.request.sshPID == pid, let sheet = current.sheet {
            sheet.window.endSheet(sheet.alert.window, returnCode: .abort)
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
        alert.informativeText = Self.displayText(request.prompt)
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

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: AppDelegate.isTerminalWindowCandidate)
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
                settle(pending, .text(password))
            } else {
                current = nil
                queue.insert(pending, at: 0)
                presentNext()
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

    /// ssh's prompt with its control characters removed, and capped.
    static func displayText(_ prompt: String) -> String {
        let scalars = prompt.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars).prefix(2048)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
