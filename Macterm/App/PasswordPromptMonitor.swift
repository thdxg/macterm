import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "PasswordPrompt")

/// Notices a pane asking for a password and drives the two offers Macterm
/// makes there: **Autofill** when a password is saved for that command and
/// prompt, and **Save** once a password the user typed has visibly worked.
/// Both appear as a bubble at the cursor (`PasswordBubble`).
///
/// Detection is `ProcessInspector.terminalIsReadingPassword` — canonical mode
/// with echo off on the pane's real tty — polled like ghostty polls its own
/// termios: every `pollInterval`, for the focused pane plus any pane with a
/// prompt, submission or offer in flight. A key typed into a pane re-reads the
/// tty on the spot (`viewWillSendKey`), so a keystroke that beats the poll to
/// a fresh prompt is still captured.
///
/// Per pane it is a small state machine (`Phase`): a first sighting must hold
/// for `confirmDelay` before it counts (a script that drops echo for an
/// instant to read a terminal reply is not a prompt — iTerm2's lesson); a
/// confirmed prompt captures what is typed through `PasswordLineCapture`; a
/// submission is judged by `PasswordSubmissionJudge`, and only a success
/// becomes a save offer.
///
/// The captured password lives in memory only until the offer is answered or
/// dropped, is never logged, and never reaches the CLI or App Intents.
@MainActor
final class PasswordPromptMonitor {
    static let shared = PasswordPromptMonitor()

    static let pollInterval: TimeInterval = 0.15
    static let confirmDelay: TimeInterval = 0.2

    struct Prompt {
        let id: PasswordEntryID
        var capture = PasswordLineCapture()
        let isSaved: Bool
        /// This prompt is the saved password's rejection being asked again.
        let savedWasRejected: Bool
        var dismissed = false
        var autofilling = false
    }

    struct Submission {
        let id: PasswordEntryID
        let secret: String
        let judge: PasswordSubmissionJudge
        let fromAutofill: Bool
        let wasSaved: Bool
        let savedWasRejected: Bool
        var exitCode: Int32?
    }

    struct Offer: Equatable {
        let id: PasswordEntryID
        let secret: String
        let isUpdate: Bool
    }

    enum Phase {
        case idle
        case sighted(since: Date, capture: PasswordLineCapture)
        case prompting(Prompt)
        case verifying(Submission)

        var isIdle: Bool {
            if case .idle = self { true } else { false }
        }
    }

    @MainActor
    final class Tracker {
        weak var view: GhosttyTerminalNSView?
        var phase: Phase = .idle
        var offer: Offer?
        /// The entry whose autofilled password was just refused; the next
        /// sighting of it says so instead of offering Autofill again.
        var rejectedAutofill: PasswordEntryID?
        let bubble = PasswordBubble()

        init(view: GhosttyTerminalNSView) {
            self.view = view
        }

        var isBusy: Bool { !phase.isIdle || offer != nil }
    }

    private var trackers: [ObjectIdentifier: Tracker] = [:]
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let vault: PasswordVault
    private let now: () -> Date

    init(vault: PasswordVault = .shared, now: @escaping () -> Date = Date.init) {
        self.vault = vault
        self.now = now
    }

    /// Begin polling. Called once the app has finished launching.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PasswordPromptMonitor.shared.scheduleIfNeeded() }
            },
        ]
        scheduleIfNeeded()
    }

    // MARK: - Inputs from the terminal view

    /// A key is about to reach libghostty. Bring the pane's state up to date
    /// first (the tty is still at the prompt that will receive this key),
    /// then feed the key to the capture.
    func viewWillSendKey(_ view: GhosttyTerminalNSView, event: NSEvent) {
        guard let input = PasswordKeyInput.from(event) else { return }
        receive(input, in: view)
    }

    /// A paste reached the surface. At a prompt it is part of the password.
    func viewDidPaste(_ view: GhosttyTerminalNSView, text: String) {
        guard !text.isEmpty else { return }
        receive(.text(text), in: view)
    }

    /// OSC 133;D: shell integration's exit code for the command that just
    /// finished — the clearest verdict a submission can get.
    func viewDidFinishCommand(_ view: GhosttyTerminalNSView, exitCode: Int32) {
        guard let tracker = trackers[ObjectIdentifier(view)],
              case var .verifying(submission) = tracker.phase
        else { return }
        submission.exitCode = exitCode
        tracker.phase = .verifying(submission)
        step(tracker)
    }

    /// The view's pane is going away: drop everything it anchors, secret
    /// included.
    func forget(_ view: GhosttyTerminalNSView) {
        guard let tracker = trackers.removeValue(forKey: ObjectIdentifier(view)) else { return }
        tracker.bubble.close()
    }

    private func receive(_ input: PasswordKeyInput, in view: GhosttyTerminalNSView) {
        let tracker = tracker(for: view)
        step(tracker)
        switch tracker.phase {
        case .idle,
             .verifying:
            // Return at an ordinary prompt means the user has moved on: an
            // unanswered save offer is dropped rather than left to pile up.
            if input == .submit, tracker.phase.isIdle, tracker.offer != nil {
                tracker.offer = nil
                refreshBubble(tracker)
            }
            return
        case .sighted:
            // Typing at it is evidence enough that it is a real prompt.
            confirm(tracker)
        case .prompting:
            break
        }
        guard case var .prompting(prompt) = tracker.phase else { return }
        switch prompt.capture.apply(input) {
        case .editing,
             .cancelled:
            tracker.phase = .prompting(prompt)
        case let .submitted(secret):
            tracker.phase = .verifying(Submission(
                id: prompt.id,
                secret: secret,
                judge: PasswordSubmissionJudge(submittedPrompt: prompt.id.prompt, submittedAt: now()),
                fromAutofill: false,
                wasSaved: prompt.isSaved,
                savedWasRejected: prompt.savedWasRejected
            ))
            logger.info("password submitted; judging")
        }
        refreshBubble(tracker)
        scheduleIfNeeded()
    }

    // MARK: - Autofill

    /// The focused terminal view, if its prompt has a saved password.
    var canAutofillFocused: Bool {
        guard let view = focusedView(), let tracker = trackers[ObjectIdentifier(view)] else { return false }
        if case let .prompting(prompt) = tracker.phase { return prompt.isSaved && !prompt.autofilling }
        return false
    }

    func autofillFocused() {
        guard let view = focusedView() else { return }
        autofill(in: view)
    }

    func autofill(in view: GhosttyTerminalNSView) {
        guard let tracker = trackers[ObjectIdentifier(view)],
              case var .prompting(prompt) = tracker.phase,
              prompt.isSaved, !prompt.autofilling
        else {
            NSSound.beep()
            return
        }
        prompt.autofilling = true
        prompt.dismissed = false
        tracker.phase = .prompting(prompt)
        refreshBubble(tracker)
        let id = prompt.id
        Task { @MainActor [weak view] in
            let authorized = await PasswordAuthenticator.shared.authorize(
                reason: "autofill the password for “\(id.title)”"
            )
            guard let view else { return }
            self.finishAutofill(in: view, id: id, authorized: authorized)
        }
    }

    private func finishAutofill(in view: GhosttyTerminalNSView, id: PasswordEntryID, authorized: Bool) {
        guard let tracker = trackers[ObjectIdentifier(view)],
              case var .prompting(prompt) = tracker.phase,
              prompt.id == id
        else { return }
        prompt.autofilling = false
        tracker.phase = .prompting(prompt)
        defer {
            refreshBubble(tracker)
            // The authentication sheet took key; typing belongs back here.
            PasswordBubble.returnKey(to: view)
        }
        guard authorized else { return }
        // Authentication took a moment; the program may have given up.
        guard let pane = view.owningPane, ProcessInspector.terminalIsReadingPassword(forPane: pane) else { return }
        guard let secret = vault.password(for: id) else {
            NSSound.beep()
            return
        }
        // Whatever was already typed at this prompt would prefix the saved
        // password; ⌃U (the tty's line kill) clears it first.
        if !prompt.capture.buffer.isEmpty || prompt.capture.isTainted {
            view.sendKey(keyCode: 32, mods: .control)
        }
        view.sendSecret(secret)
        tracker.phase = .verifying(Submission(
            id: id,
            secret: "",
            judge: PasswordSubmissionJudge(submittedPrompt: id.prompt, submittedAt: now()),
            fromAutofill: true,
            wasSaved: true,
            savedWasRejected: false
        ))
        logger.info("autofilled saved password; judging")
        scheduleIfNeeded()
    }

    // MARK: - Polling

    private func tracker(for view: GhosttyTerminalNSView) -> Tracker {
        let key = ObjectIdentifier(view)
        if let existing = trackers[key] { return existing }
        let tracker = Tracker(view: view)
        tracker.bubble.actions = actions(for: tracker)
        trackers[key] = tracker
        return tracker
    }

    private func focusedView() -> GhosttyTerminalNSView? {
        guard NSApp.isActive else { return nil }
        return NSApp.keyWindow?.firstResponder as? GhosttyTerminalNSView
    }

    private func scheduleIfNeeded() {
        let needed = NSApp.isActive || trackers.values.contains(where: \.isBusy)
        if needed, timer == nil {
            let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { _ in
                MainActor.assumeIsolated { PasswordPromptMonitor.shared.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needed, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    private func tick() {
        let focused = focusedView()
        if let focused { _ = tracker(for: focused) }
        for (key, tracker) in trackers {
            guard let view = tracker.view, view.owningPane != nil else {
                tracker.bubble.close()
                trackers[key] = nil
                continue
            }
            let isFocused = view === focused
            if isFocused || !tracker.phase.isIdle {
                step(tracker)
            }
            refreshBubble(tracker)
            if !isFocused, !tracker.isBusy {
                view.detectedPasswordInput = false
                tracker.bubble.close()
                trackers[key] = nil
            }
        }
        scheduleIfNeeded()
    }

    /// Advance one pane's state machine against its tty and screen now.
    private func step(_ tracker: Tracker) {
        guard let view = tracker.view, let pane = view.owningPane else { return }
        let atPrompt = ProcessInspector.terminalIsReadingPassword(forPane: pane)
        view.detectedPasswordInput = atPrompt && GhosttyApp.shared.autoSecureInput
        let time = now()
        switch tracker.phase {
        case .idle:
            if atPrompt { tracker.phase = .sighted(since: time, capture: PasswordLineCapture()) }
        case let .sighted(since, _):
            if !atPrompt {
                tracker.phase = .idle
            } else if time.timeIntervalSince(since) >= Self.confirmDelay {
                confirm(tracker)
            }
        case .prompting:
            // Ended without a Return we saw: ⌃C, or the program gave up.
            if !atPrompt { tracker.phase = .idle }
        case let .verifying(submission):
            judge(submission, in: tracker, view: view, atPrompt: atPrompt, time: time)
        }
    }

    /// A sighting held: read which prompt it is and whether a password is
    /// saved for it.
    private func confirm(_ tracker: Tracker) {
        guard let view = tracker.view, let pane = view.owningPane,
              case let .sighted(_, capture) = tracker.phase
        else { return }
        guard let screen = view.readText(scrollback: false),
              let prompt = PasswordPromptIdentity.promptLine(fromViewport: screen)
        else {
            tracker.phase = .idle
            return
        }
        let id = PasswordPromptIdentity.entryID(prompt: prompt, command: Self.command(for: pane))
        let rejected = tracker.rejectedAutofill == id
        tracker.rejectedAutofill = nil
        tracker.phase = .prompting(Prompt(
            id: id,
            capture: capture,
            isSaved: vault.contains(id),
            savedWasRejected: rejected
        ))
        logger.info("password prompt confirmed saved=\(self.vault.contains(id), privacy: .public)")
    }

    /// The command that asked. A remote project's pane is Macterm's own ssh
    /// wrapper, filed under the connection it makes; everything else is the
    /// foreground process's argv.
    static func command(for pane: Pane) -> String? {
        if pane.isRemote {
            guard case let .remote(user, host, _)? = ProjectPath.parse(pane.projectPath) else { return nil }
            return PasswordPromptIdentity.remoteCommand(user: user, host: host)
        }
        return ProcessInspector.runningCommand(forPane: pane)
    }

    private func judge(
        _ submission: Submission,
        in tracker: Tracker,
        view: GhosttyTerminalNSView,
        atPrompt: Bool,
        time: Date
    ) {
        let screen = view.readText(scrollback: false) ?? ""
        let verdict = submission.judge.evaluate(.init(
            now: time,
            atPasswordPrompt: atPrompt,
            currentPrompt: atPrompt ? PasswordPromptIdentity.promptLine(fromViewport: screen) : nil,
            outputAfterPrompt: PasswordSubmissionJudge.output(after: submission.id.prompt, inViewport: screen),
            exitCode: submission.exitCode
        ))
        guard verdict != .pending else { return }
        let outcome = String(describing: verdict)
        logger.info("password submission verdict=\(outcome, privacy: .public) autofill=\(submission.fromAutofill, privacy: .public)")
        switch verdict {
        case .succeeded:
            let wantsOffer = !submission.fromAutofill
                && !submission.secret.isEmpty
                && Preferences.shared.offerToSavePasswords
                && (!submission.wasSaved || submission.savedWasRejected)
            if wantsOffer {
                tracker.offer = Offer(id: submission.id, secret: submission.secret, isUpdate: submission.wasSaved)
            }
        case .failed:
            if submission.fromAutofill { tracker.rejectedAutofill = submission.id }
        case .undetermined,
             .pending:
            break
        }
        // A prompt still showing is the next one (or the same one again): it
        // gets its own sighting.
        tracker.phase = atPrompt ? .sighted(since: time, capture: PasswordLineCapture()) : .idle
    }

    // MARK: - Bubble

    private func actions(for tracker: Tracker) -> PasswordBubble.Actions {
        PasswordBubble.Actions(
            autofill: { [weak self, weak tracker] in
                guard let view = tracker?.view else { return }
                self?.autofill(in: view)
            },
            dismiss: { [weak self, weak tracker] in
                guard let tracker, case var .prompting(prompt) = tracker.phase else { return }
                prompt.dismissed = true
                tracker.phase = .prompting(prompt)
                self?.refreshBubble(tracker)
            },
            save: { [weak self, weak tracker] in
                guard let self, let tracker, let offer = tracker.offer else { return }
                tracker.offer = nil
                vault.save(offer.secret, for: offer.id)
                refreshBubble(tracker)
            },
            cancelOffer: { [weak self, weak tracker] in
                guard let tracker else { return }
                tracker.offer = nil
                self?.refreshBubble(tracker)
            },
            removeSaved: { [weak self, weak tracker] in
                guard let self, let tracker, case var .prompting(prompt) = tracker.phase else { return }
                vault.remove(prompt.id)
                prompt.dismissed = true
                tracker.phase = .prompting(prompt)
                refreshBubble(tracker)
            }
        )
    }

    private func refreshBubble(_ tracker: Tracker) {
        guard let view = tracker.view else {
            tracker.bubble.close()
            return
        }
        let content = bubbleContent(for: tracker)
        let anchor = Self.isShowing(view) ? view.cursorCellRect() : nil
        tracker.bubble.show(content, anchor: anchor, in: view)
    }

    private func bubbleContent(for tracker: Tracker) -> PasswordBubble.Content? {
        switch tracker.phase {
        case let .prompting(prompt) where !prompt.dismissed:
            if prompt.savedWasRejected { return .rejected(prompt.id) }
            if prompt.isSaved { return .autofill(prompt.id, busy: prompt.autofilling) }
            return nil
        case .idle:
            // Held while a prompt is up so it never crowds one.
            return tracker.offer.map { .save($0.id, isUpdate: $0.isUpdate) }
        default:
            return nil
        }
    }

    /// The pane is on screen: in a visible window, not zoomed away, not in a
    /// hidden tab.
    private static func isShowing(_ view: GhosttyTerminalNSView) -> Bool {
        guard let window = view.window, window.isVisible,
              window.occlusionState.contains(.visible),
              !view.isHiddenOrHasHiddenAncestor,
              !view.hiddenInLayout
        else { return false }
        return true
    }
}

extension PasswordKeyInput {
    /// What a key event does to the line a password read is collecting, or
    /// nil for a key that isn't input to it at all (⌘ chords — a paste
    /// arrives through `viewDidPaste` — and bare modifiers).
    static func from(_ event: NSEvent) -> PasswordKeyInput? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command) { return nil }
        switch event.keyCode {
        case 36,
             76: return flags.contains(.control) ? .unknown : .submit
        case 51: return .backspace
        // Escape, forward delete, home, end, page up/down, arrows.
        case 53,
             117,
             115,
             119,
             116,
             121,
             123,
             124,
             125,
             126: return .unknown
        default: break
        }
        if flags.contains(.control) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "u": return .killLine
            case "w": return .killWord
            case "h": return .backspace
            case "c",
                 "d": return .cancel
            default: return .unknown
            }
        }
        guard let text = event.characters, !text.isEmpty else { return .unknown }
        // Function keys arrive as private-use characters, other control keys
        // as C0 codes; neither is text the line keeps (tab is).
        let unprintable = text.unicodeScalars.contains { scalar in
            (0xF700 ... 0xF8FF).contains(scalar.value) || (scalar.value < 0x20 && scalar != "\t")
        }
        return unprintable ? .unknown : .text(text)
    }
}
