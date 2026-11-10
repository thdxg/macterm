import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "SSHLoginPrompts")

/// The questions that the login of a host's ssh master asks, shown as sheets
/// (design/005 step 2): a secure field for a password or a passphrase, or
/// Connect and Cancel for a host key and a confirmation. One sheet at a time;
/// the next waits. The text is Macterm's for a question that it knows
/// (`Question`), and ssh's prompt line for any other.
///
/// A login that writes text and asks nothing (a host that waits for a log-in
/// in the browser) gets a notice sheet with ssh's last line and Cancel
/// (`SSHConnections.onLoginNotice`). It has Open Link when that line holds
/// an https link. The notice closes when the login ends.
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
        showNotice(host: "", sshPID: pid, line: nil)
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

    // MARK: - Notice

    /// The notice of each login that waits, in the order they came. One
    /// sheet shows the first, when no question is open; the others wait.
    private var notices: [Notice] = []

    private struct Notice {
        var sshPID: pid_t
        var host: String
        var line: String
    }

    private var noticeSheet: NoticeSheet?
    /// Logins whose notice brought the app to the front once.
    private var activatedNotices: Set<pid_t> = []

    private struct NoticeSheet {
        var sshPID: pid_t
        var alert: NSAlert
        var window: NSWindow
        var line: String
        /// The Open Link button's target, kept while the sheet is up.
        var opener: LinkOpener?
    }

    /// Show `line` for the login of the master `pid`, or remove its notice
    /// when `line` is nil.
    func showNotice(host: String, sshPID pid: pid_t, line: String?) {
        if let line, !line.isEmpty {
            if let index = notices.firstIndex(where: { $0.sshPID == pid }) {
                notices[index].line = line
            } else {
                notices.append(Notice(sshPID: pid, host: host, line: line))
            }
        } else {
            notices.removeAll { $0.sshPID == pid }
            activatedNotices.remove(pid)
        }
        refreshNotice()
    }

    /// Show the first notice when no question is open, or close the sheet.
    private func refreshNotice() {
        let wanted = current == nil && queue.isEmpty ? notices.first : nil
        if let sheet = noticeSheet {
            if let wanted, wanted.sshPID == sheet.sshPID, (Self.link(in: wanted.line) == nil) == (sheet.opener == nil) {
                // The same login: change the text in place, so that a
                // line that changes does not open the sheet again.
                if wanted.line != sheet.line {
                    sheet.alert.informativeText = wanted.line
                    if let url = Self.link(in: wanted.line) { sheet.opener?.url = url }
                    noticeSheet?.line = wanted.line
                }
                return
            }
            closeNoticeSheet()
        }
        // No terminal window: no notice. A modal alert would hold the wait
        // for the login that closes it.
        guard let wanted, let window = Self.terminalWindow() else { return }
        let pid = wanted.sshPID
        let alert = NSAlert()
        alert.messageText = String(localized: "Connecting to \(wanted.host)")
        alert.informativeText = wanted.line
        var opener: LinkOpener?
        if let url = Self.link(in: wanted.line) {
            let button = alert.addButton(withTitle: String(localized: "Open Link"))
            // Its own action: the sheet stays up until the login ends.
            let target = LinkOpener(url: url)
            button.target = target
            button.action = #selector(LinkOpener.open(_:))
            opener = target
        }
        alert.addButton(withTitle: String(localized: "Cancel"))
        noticeSheet = NoticeSheet(sshPID: pid, alert: alert, window: window, line: wanted.line, opener: opener)
        if activatedNotices.insert(pid).inserted { NSApp.activate() }
        let host = wanted.host
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, noticeSheet?.alert === alert else { return }
            noticeSheet = nil
            guard response != .abort else { return }
            logger.info("ssh notice for host=\(host, privacy: .public): cancelled")
            notices.removeAll { $0.sshPID == pid }
            SSHConnections.shared.cancelLogin(connectionPID: pid)
            refreshNotice()
        }
    }

    private func closeNoticeSheet() {
        guard let sheet = noticeSheet else { return }
        noticeSheet = nil
        sheet.window.endSheet(sheet.alert.window, returnCode: .abort)
    }

    private final class LinkOpener: NSObject {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        @objc
        func open(_: Any?) {
            NSWorkspace.shared.open(url)
        }
    }

    /// The first https link in `line`, without the punctuation around it.
    nonisolated static func link(in line: String) -> URL? {
        for word in line.split(whereSeparator: \.isWhitespace) {
            guard let start = word.range(of: "https://", options: .caseInsensitive)?.lowerBound else { continue }
            let trimmed = word[start...].trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)]}>'\""))
            if let url = URL(string: trimmed), url.scheme?.lowercased() == "https", url.host?.isEmpty == false { return url }
        }
        return nil
    }

    /// A terminal window: the key window can be the quick terminal, a
    /// desktop widget or a popover, which a sheet does not suit.
    static func terminalWindow() -> NSWindow? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap(\.self) + NSApp.windows.filter(\.isVisible)
        return candidates.first(where: { AppDelegate.isTerminalWindowCandidate($0) })
    }

    // MARK: - Sheets

    private enum Button {
        static let primary = NSApplication.ModalResponse.alertFirstButtonReturn
        static let cancel = NSApplication.ModalResponse.alertSecondButtonReturn
        static let saved = NSApplication.ModalResponse.alertThirdButtonReturn
    }

    private func presentNext() {
        guard current == nil, !queue.isEmpty else { return refreshNotice() }
        // A question has the window first. Its notice comes back after.
        closeNoticeSheet()
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
        let question = Question.of(request.prompt, kind: request.kind)
        var fingerprint: NSTextField?
        var text = question.text
        if case let .hostKey(key) = question {
            let label = NSTextField(labelWithString: "\(key.host)\n\(key.type) \(key.fingerprint)")
            label.font = TerminalFont.shared.nsFont(size: NSFont.smallSystemFontSize)
            label.isSelectable = true
            label.lineBreakMode = .byClipping
            label.sizeToFit()
            fingerprint = label
        }
        if Self.isRetry(request, answered: answeredSecret) {
            text = question.refusal + "\n" + text
        }
        alert.informativeText = text
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

        guard let window = Self.terminalWindow() else {
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

    /// What a question of the login is. Macterm knows a question only by the
    /// exact text that OpenSSH writes for it, and shows its own text for it.
    /// Any other text (a code of an authenticator app, a text that the host's
    /// administrator wrote) is unknown: the sheet shows only ssh's prompt
    /// line, never its other output.
    enum Question: Equatable {
        /// `bob@box's password: `, or `(bob@box) Password: ` of a
        /// keyboard-interactive login.
        case password(account: String)
        /// `Enter passphrase for key '<file>': `.
        case passphrase(key: String)
        case hostKey(HostKey)
        /// ssh's prompt line, or for a yes or no question the lines above it.
        case unknown(line: String)

        static func of(_ prompt: String, kind: Kind) -> Question {
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            switch kind {
            case .secret:
                if let account = password(in: text) { return .password(account: account) }
                if let key = passphraseKey(in: text) { return .passphrase(key: key) }
            case .yesNo:
                if let key = SSHLoginPrompts.hostKey(in: prompt) { return .hostKey(key) }
                // A yes or no question is about the host's key (a key that
                // changed, a form that a later OpenSSH writes). Fail closed:
                // keep ssh's lines above the question, so that the host and
                // the key stay in view. The buttons ask the question.
                let lines = SSHLoginPrompts.displayText(prompt).split(whereSeparator: \.isNewline)
                if lines.count > 1 { return .unknown(line: lines.dropLast().joined(separator: "\n")) }
            case .confirm:
                break
            }
            return .unknown(line: SSHLoginPrompts.promptLine(prompt))
        }

        /// The sheet's text.
        var text: String {
            switch self {
            case let .password(account): String(localized: "Type the password for \(account).")
            case let .passphrase(key): String(localized: "Type the passphrase for the key \(key).")
            case .hostKey: String(localized: "The key of this host is not known. Make sure that it is the key that you expect.")
            case let .unknown(line): line
            }
        }

        /// The line in front of the text when ssh asks the same again.
        var refusal: String {
            switch self {
            case .password: String(localized: "The password is incorrect.")
            case .passphrase: String(localized: "The passphrase is incorrect.")
            case .hostKey,
                 .unknown: String(localized: "The answer is incorrect.")
            }
        }

        private static func password(in text: String) -> String? {
            if text.hasSuffix("'s password:") {
                let account = String(text.dropLast("'s password:".count))
                return isAccount(account) ? account : nil
            }
            if text.hasPrefix("("), text.hasSuffix(") Password:") {
                let account = String(text.dropFirst().dropLast(") Password:".count))
                return isAccount(account) ? account : nil
            }
            return nil
        }

        /// `user@host`, one word.
        private static func isAccount(_ text: String) -> Bool {
            let parts = text.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty }
                && !text.contains(where: { $0.isWhitespace || $0 == "'" || $0 == "(" || $0 == ")" })
        }

        private static func passphraseKey(in text: String) -> String? {
            let opening = "Enter passphrase for key '"
            let closing = "':"
            guard text.hasPrefix(opening), text.hasSuffix(closing), text.count > opening.count + closing.count else { return nil }
            let path = String(text.dropFirst(opening.count).dropLast(closing.count))
            guard !path.contains("\n") else { return nil }
            return (path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// The last line of ssh's prompt that has text, cleaned: what the sheet
    /// shows for a question that Macterm does not know.
    nonisolated static func promptLine(_ prompt: String) -> String {
        displayText(prompt).split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
    }

    /// The host, key type and fingerprint of ssh's question about a new host
    /// key ("The authenticity of host 'box (1.2.3.4)' can't be established."
    /// and "ED25519 key fingerprint is SHA256:…." or, from OpenSSH 10.5,
    /// "ED25519 key fingerprint is: SHA256:…"), or nil when either line
    /// is missing. With `ProxyJump` the key can be the jump host's, so the
    /// sheet shows the host that ssh names.
    nonisolated static func hostKey(in prompt: String) -> HostKey? {
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

    /// ssh's prompt with its control characters removed, and capped.
    nonisolated static func displayText(_ prompt: String) -> String {
        let scalars = prompt.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(scalars).prefix(2048)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
