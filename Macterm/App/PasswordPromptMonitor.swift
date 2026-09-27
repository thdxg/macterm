import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "PasswordPrompt")

/// Notices a pane asking for a password and drives the two offers Macterm
/// makes there: **Autofill** when a password is saved for that command and
/// prompt, and **Save** once a password the user typed has visibly worked.
/// Both appear as a bubble at the cursor (`PasswordBubble`).
///
/// Detection is `ProcessInspector.terminalIsReadingPassword` — canonical mode
/// with echo off on the pane's real tty. It is read on three cues: an output
/// heartbeat from the pane (`viewDidOutput`, which is when a prompt gets
/// printed), every key typed into the pane (`viewWillSendKey`, before the key
/// reaches libghostty, so the prompt that receives it is still up), and a
/// timer — slow (`idleInterval`) for the focused pane while nothing is
/// happening, fast (`busyInterval`) only while some pane has a prompt,
/// submission or offer in flight, so the idle app wakes no more often than
/// its existing polls.
///
/// Per pane it is a small state machine (`Phase`): a first sighting must hold
/// for `confirmDelay` before it counts (a script that drops echo for an
/// instant to read a terminal reply is not a prompt — iTerm2's lesson) unless
/// the user types at it; a confirmed prompt captures what is typed through
/// `PasswordLineCapture`; a submission is judged by `PasswordSubmissionJudge`,
/// and only a success becomes a save offer. Offers queue (`ssh -J` yields two
/// in a row) and show one at a time, once no prompt is up.
///
/// While a bubble is up and nothing has been typed since it appeared, Return
/// is its primary button and Escape dismisses it; the first typed character
/// hands both keys back to the terminal, so a password or command typed under
/// the bubble submits as usual, and a typed-then-submitted command drops an
/// unanswered save offer.
///
/// The captured password lives in memory only until the offer is answered or
/// dropped, is never logged, and never reaches the CLI or App Intents.
@MainActor
final class PasswordPromptMonitor {
    static let shared = PasswordPromptMonitor()

    static let idleInterval: TimeInterval = 1.0
    static let busyInterval: TimeInterval = 0.15
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

        var name: String {
            switch self {
            case .idle: "idle"
            case .sighted: "sighted"
            case .prompting: "prompting"
            case .verifying: "verifying"
            }
        }
    }

    /// The bubble's buttons, as the debug control verb names them.
    enum Reply: String {
        case accept
        case dismiss
        case autofill
    }

    @MainActor
    final class Tracker {
        weak var view: GhosttyTerminalNSView?
        var phase: Phase = .idle
        /// Save offers waiting to be shown, oldest first.
        var offers: [Offer] = []
        /// The entry whose autofilled password was just refused; the next
        /// sighting of it says so instead of offering Autofill again.
        var rejectedAutofill: PasswordEntryID?
        /// Something was typed into the pane since the current bubble
        /// appeared, which hands Return and Escape back to the terminal.
        var typedSinceBubble = false
        let bubble = PasswordBubble()

        init(view: GhosttyTerminalNSView) {
            self.view = view
        }

        var offer: Offer? { offers.first }
        var isBusy: Bool { !phase.isIdle || !offers.isEmpty }
    }

    private var trackers: [ObjectIdentifier: Tracker] = [:]
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    /// True while the monitor itself is typing into a pane (autofill), so
    /// its own keystrokes aren't captured as the user's.
    private var isInjecting = false
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

    /// A key is about to reach libghostty. Returns true when the bubble took
    /// it (Return as its primary button, Escape as Dismiss) and the terminal
    /// must not see it; otherwise the key is fed to the capture.
    func viewWillSendKey(_ view: GhosttyTerminalNSView, event: NSEvent) -> Bool {
        guard !isInjecting, let input = PasswordKeyInput.from(event) else { return false }
        return receive(input, in: view)
    }

    /// Text reached the surface outside a key event: a paste, or the control
    /// CLI's `pane run`. At a prompt it is (part of) the password.
    func viewDidSendText(_ view: GhosttyTerminalNSView, text: String) {
        guard !isInjecting, !text.isEmpty else { return }
        _ = receive(.text(text), in: view)
    }

    /// A paste reached the surface. At a prompt it is part of the password.
    func viewDidPaste(_ view: GhosttyTerminalNSView, text: String) {
        viewDidSendText(view, text: text)
    }

    /// A chord sent through the control CLI's `pane key`, which bypasses
    /// `keyDown`. Mapped like a key event so ⌃U, Return and the rest mean the
    /// same to the capture whichever way they arrive.
    func viewDidSendKey(_ view: GhosttyTerminalNSView, keyCode: UInt16, mods: NSEvent.ModifierFlags) {
        guard !isInjecting else { return }
        let text = mods.isDisjoint(with: [.control, .command, .option])
            ? HotkeyRegistry.printableText(forKeyCode: keyCode, shift: mods.contains(.shift))
            : nil
        let input = PasswordKeyInput.from(
            keyCode: keyCode,
            flags: mods,
            characters: text,
            charactersIgnoringModifiers: HotkeyRegistry.baseToken(forKeyCode: keyCode)
        )
        guard let input else { return }
        _ = receive(input, in: view)
    }

    /// The pane printed something. A prompt is output, so read the tty now.
    func viewDidOutput(_ view: GhosttyTerminalNSView) {
        guard let tracker = trackers[ObjectIdentifier(view)] ?? (view === focusedView() ? tracker(for: view) : nil)
        else { return }
        _ = step(tracker)
        refreshBubble(tracker)
        scheduleIfNeeded()
    }

    /// OSC 133;D: shell integration's exit code for the command that just
    /// finished — the clearest verdict a submission can get.
    func viewDidFinishCommand(_ view: GhosttyTerminalNSView, exitCode: Int32) {
        guard let tracker = trackers[ObjectIdentifier(view)],
              case var .verifying(submission) = tracker.phase
        else { return }
        submission.exitCode = exitCode
        tracker.phase = .verifying(submission)
        _ = step(tracker)
        refreshBubble(tracker)
    }

    /// The view's pane is going away: drop everything it anchors, secret
    /// included.
    func forget(_ view: GhosttyTerminalNSView) {
        guard let tracker = trackers.removeValue(forKey: ObjectIdentifier(view)) else { return }
        tracker.bubble.close()
    }

    /// Feed one input to the pane's state machine. Returns true when a
    /// visible bubble consumed it.
    private func receive(_ input: PasswordKeyInput, in view: GhosttyTerminalNSView) -> Bool {
        let tracker = tracker(for: view)
        let atPrompt = step(tracker)
        defer {
            refreshBubble(tracker)
            scheduleIfNeeded()
        }
        // A bubble with nothing typed under it yet owns Return and Escape.
        if tracker.bubble.isShown, !tracker.typedSinceBubble {
            switch input {
            case .submit:
                if let reply = primaryReply(for: tracker) {
                    _ = answer(reply, in: view)
                    return true
                }
            case .escape:
                _ = answer(.dismiss, in: view)
                return true
            default:
                break
            }
        }
        if input != .submit, input != .escape { tracker.typedSinceBubble = true }

        switch tracker.phase {
        case .idle:
            // A command typed and run at an ordinary prompt means the user
            // has moved on: an unanswered save offer is dropped rather than
            // left to pile up. A bare Return (a new prompt line) keeps it.
            if input == .submit, tracker.typedSinceBubble, !tracker.offers.isEmpty {
                tracker.offers.removeAll()
            }
            return false
        case let .verifying(submission):
            // Typing at a prompt that is up before the judge has settled is
            // the user answering the next read: resolve now, so the first
            // characters of the retyped password aren't lost.
            guard atPrompt, case .text = input else { return false }
            settle(submission, in: tracker, view: view, atPrompt: true, time: now())
            guard case .sighted = tracker.phase else { return false }
            confirm(tracker)
        case .sighted:
            // Typing at it is evidence enough that it is a real prompt.
            confirm(tracker)
        case .prompting:
            break
        }
        guard case var .prompting(prompt) = tracker.phase else { return false }
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
        return false
    }

    // MARK: - Answering the bubble

    /// The focused terminal view, if its prompt has a saved password.
    var canAutofillFocused: Bool {
        guard let view = focusedView(), let tracker = trackers[ObjectIdentifier(view)] else { return false }
        if case let .prompting(prompt) = tracker.phase { return prompt.isSaved && !prompt.autofilling }
        return false
    }

    func autofillFocused() {
        guard let view = focusedView() else { return }
        _ = answer(.autofill, in: view)
    }

    /// Press one of the bubble's buttons for `view`'s pane. False when that
    /// button isn't offered right now.
    @discardableResult
    func answer(_ reply: Reply, in view: GhosttyTerminalNSView) -> Bool {
        guard let tracker = trackers[ObjectIdentifier(view)] else { return false }
        defer { refreshBubble(tracker) }
        switch (reply, tracker.phase) {
        case (.autofill, .prompting):
            return autofill(in: view)
        case var (.dismiss, .prompting(prompt)):
            prompt.dismissed = true
            tracker.phase = .prompting(prompt)
            return true
        case var (.accept, .prompting(prompt)) where prompt.savedWasRejected:
            // The rejected bubble's primary button is OK.
            prompt.dismissed = true
            tracker.phase = .prompting(prompt)
            return true
        case (.accept, .idle):
            guard !tracker.offers.isEmpty else { return false }
            let offer = tracker.offers.removeFirst()
            vault.save(offer.secret, for: offer.id)
            return true
        case (.dismiss, .idle):
            guard !tracker.offers.isEmpty else { return false }
            tracker.offers.removeFirst()
            return true
        default:
            return false
        }
    }

    /// What Return does under the bubble that is up.
    private func primaryReply(for tracker: Tracker) -> Reply? {
        switch bubbleContent(for: tracker) {
        case .autofill(_, busy: false): .autofill
        case .autofill: nil
        case .rejected: .accept
        case .save: .accept
        case nil: nil
        }
    }

    /// The monitor's view of a pane, for the debug control verb.
    func state(for view: GhosttyTerminalNSView?) -> ControlPasswordState {
        guard let view, let tracker = trackers[ObjectIdentifier(view)] else {
            return ControlPasswordState(phase: "idle", saved: false)
        }
        var state = ControlPasswordState(phase: tracker.phase.name, saved: false)
        if case let .prompting(prompt) = tracker.phase {
            state.prompt = prompt.id.prompt
            state.command = prompt.id.command
            state.saved = prompt.isSaved
        }
        state.bubble = switch bubbleContent(for: tracker) {
        case .autofill: "autofill"
        case .rejected: "rejected"
        case .save(_, isUpdate: true): "update"
        case .save: "save"
        case nil: nil
        }
        return state
    }

    private func autofill(in view: GhosttyTerminalNSView) -> Bool {
        guard let tracker = trackers[ObjectIdentifier(view)],
              case var .prompting(prompt) = tracker.phase,
              prompt.isSaved, !prompt.autofilling
        else {
            NSSound.beep()
            return false
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
        return true
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
            tracker.bubble.returnKey(to: view)
        }
        guard authorized else { return }
        // Authentication took a moment; the program may have given up.
        guard let pane = view.owningPane, ProcessInspector.terminalIsReadingPassword(forPane: pane) else { return }
        guard let secret = vault.password(for: id) else {
            NSSound.beep()
            return
        }
        isInjecting = true
        defer { isInjecting = false }
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
        let busy = trackers.values.contains(where: \.isBusy)
        let wanted: TimeInterval? = busy ? Self.busyInterval : (NSApp.isActive ? Self.idleInterval : nil)
        guard wanted != (timer == nil ? nil : timerInterval) else { return }
        timer?.invalidate()
        timer = nil
        guard let wanted else { return }
        let timer = Timer(timeInterval: wanted, repeats: true) { _ in
            MainActor.assumeIsolated { PasswordPromptMonitor.shared.tick() }
        }
        // The idle poll is a courtesy check; let the system batch it.
        timer.tolerance = busy ? 0 : wanted / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        timerInterval = wanted
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
                _ = step(tracker)
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
    /// Returns whether the tty is at a password read.
    @discardableResult
    private func step(_ tracker: Tracker) -> Bool {
        guard let view = tracker.view, let pane = view.owningPane else { return false }
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
        return atPrompt
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
        conclude(submission, verdict: verdict, in: tracker, atPrompt: atPrompt, time: time)
    }

    /// Decide a submission from the prompt alone, without waiting for the
    /// settle delay: the user has started typing at a prompt, so the read
    /// the submission fed is over.
    private func settle(
        _ submission: Submission,
        in tracker: Tracker,
        view: GhosttyTerminalNSView,
        atPrompt: Bool,
        time: Date
    ) {
        let screen = view.readText(scrollback: false) ?? ""
        let current = PasswordPromptIdentity.promptLine(fromViewport: screen)
        let verdict: PasswordSubmissionJudge.Verdict = if let code = submission.exitCode, code >= 0 {
            code == 0 ? .succeeded : .failed
        } else if PasswordSubmissionJudge.containsFailure(
            PasswordSubmissionJudge.output(after: submission.id.prompt, inViewport: screen)
        ) {
            .failed
        } else {
            current == submission.id.prompt ? .failed : .succeeded
        }
        conclude(submission, verdict: verdict, in: tracker, atPrompt: atPrompt, time: time)
    }

    private func conclude(
        _ submission: Submission,
        verdict: PasswordSubmissionJudge.Verdict,
        in tracker: Tracker,
        atPrompt: Bool,
        time: Date
    ) {
        let outcome = String(describing: verdict)
        logger.info("password submission verdict=\(outcome, privacy: .public) autofill=\(submission.fromAutofill, privacy: .public)")
        switch verdict {
        case .succeeded:
            let wantsOffer = !submission.fromAutofill
                && !submission.secret.isEmpty
                && Preferences.shared.offerToSavePasswords
                && !PasswordPromptIdentity.isOneTimeCode(submission.id.prompt)
                && (!submission.wasSaved || submission.savedWasRejected)
            if wantsOffer {
                tracker.offers.append(Offer(id: submission.id, secret: submission.secret, isUpdate: submission.wasSaved))
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
        let reply: @MainActor (Reply) -> Void = { [weak self, weak tracker] reply in
            guard let self, let view = tracker?.view else { return }
            _ = answer(reply, in: view)
        }
        return PasswordBubble.Actions(
            primary: { reply(.accept) },
            autofill: { reply(.autofill) },
            dismiss: { reply(.dismiss) },
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
        if tracker.bubble.show(content, anchor: anchor, in: view) {
            tracker.typedSinceBubble = false
        }
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
        from(
            keyCode: event.keyCode,
            flags: event.modifierFlags,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        )
    }

    /// The tty's line discipline acts on the *byte* a key sends, so a
    /// control chord is read from its control character first (`characters`
    /// carries ⌃U as U+0015 under any layout) and from the letter only as a
    /// fallback.
    static func from(
        keyCode: UInt16,
        flags rawFlags: NSEvent.ModifierFlags,
        characters: String?,
        charactersIgnoringModifiers: String?
    ) -> PasswordKeyInput? {
        let flags = rawFlags.intersection([.command, .control, .option, .shift])
        if flags.contains(.command) { return nil }
        switch keyCode {
        case 36,
             76: return flags.contains(.control) ? .unknown : .submit
        // ⌥⌫ sends ESC DEL — the tty inserts the ESC and erases it again,
        // so the line is unchanged and nothing here can mirror that.
        case 51: return flags.contains(.option) ? .unknown : .backspace
        case 53: return .escape
        // Forward delete, home, end, page up/down, arrows.
        case 117,
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
            let control = characters?.unicodeScalars.first.map(\.value) ?? 0
            switch control {
            case 0x15: return .killLine
            case 0x17: return .killWord
            case 0x08: return .backspace
            case 0x03,
                 0x04: return .cancel
            default: break
            }
            switch charactersIgnoringModifiers?.lowercased() {
            case "u": return .killLine
            case "w": return .killWord
            case "h": return .backspace
            case "c",
                 "d": return .cancel
            default: return .unknown
            }
        }
        guard let text = characters, !text.isEmpty else { return .unknown }
        // Function keys arrive as private-use characters, other control keys
        // as C0 codes; neither is text the line keeps (tab is).
        let unprintable = text.unicodeScalars.contains { scalar in
            (0xF700 ... 0xF8FF).contains(scalar.value) || (scalar.value < 0x20 && scalar != "\t")
        }
        return unprintable ? .unknown : .text(text)
    }
}
