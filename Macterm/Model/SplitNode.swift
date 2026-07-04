import CoreGraphics
import Foundation

enum SplitDirection: String, Codable { case horizontal, vertical }
enum SplitPosition { case first, second }

/// Which edge of a pane a dragged pane is dropped onto. Determines how the
/// destination is split and on which side the dragged pane lands.
enum PaneDropZone: Equatable {
    case left
    case right
    case top
    case bottom

    /// The drop zone for a cursor position inside a pane: the four triangular
    /// regions formed by the pane's diagonals, i.e. whichever edge is closest.
    static func calculate(at point: CGPoint, in size: CGSize) -> PaneDropZone {
        guard size.width > 0, size.height > 0 else { return .right }
        let distToLeft = point.x / size.width
        let distToRight = 1 - distToLeft
        let distToTop = point.y / size.height
        let distToBottom = 1 - distToTop
        let minDist = min(distToLeft, distToRight, distToTop, distToBottom)
        if minDist == distToLeft { return .left }
        if minDist == distToRight { return .right }
        if minDist == distToTop { return .top }
        return .bottom
    }

    var splitDirection: SplitDirection {
        switch self {
        case .left,
             .right: .horizontal
        case .top,
             .bottom: .vertical
        }
    }

    var splitPosition: SplitPosition {
        switch self {
        case .left,
             .top: .first
        case .right,
             .bottom: .second
        }
    }
}

enum TerminalExecutionState: Equatable {
    case idle
    case running
    case done
}

private struct ForegroundProcessKey: Equatable {
    let name: String
    let pid: pid_t?

    init?(name: String?, pid: pid_t?) {
        let normalizedName = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !normalizedName.isEmpty else { return nil }
        self.name = normalizedName
        self.pid = pid
    }
}

private enum TerminalExecutionSource: Equatable {
    case foreground
    case activity(Date)
    case progress
}

struct TerminalExecutionTracker {
    init(hasUserInteraction: Bool = false) {
        self.hasUserInteraction = hasUserInteraction
    }

    /// The foreground process seen on the last poll (nil = idle shell / none).
    /// Transitions are driven by *changes* to this, not by re-deriving state on
    /// every poll — so a settled process doesn't flip-flop back to running just
    /// because it is still foreground.
    private var lastForeground: ForegroundProcessKey?
    /// Why the pane is currently considered running. Foreground and explicit
    /// progress run until a completion/foreground transition; activity is a
    /// render/output heartbeat and quiet-settles.
    private var runningSource: TerminalExecutionSource?
    /// After progress clears, the foreground process that owned it is
    /// "quiesced": its own output and re-polls are ignored until the foreground
    /// moves away, so a settled program that reported progress doesn't flip back
    /// to running on its own render output. `pendingProgressQuiesce` covers the
    /// race where progress started and cleared before any foreground poll.
    private var progressQuiesced: ForegroundProcessKey?
    private var pendingProgressQuiesce = false
    /// Output is ignored until the user has interacted with the pane, so a
    /// freshly-restored shell's startup prompt doesn't show as activity.
    private var hasUserInteraction = false

    mutating func recordUserInteraction() {
        hasUserInteraction = true
    }

    mutating func markProgressStarted(currentState: TerminalExecutionState) -> TerminalExecutionState {
        guard hasUserInteraction else { return currentState }
        runningSource = .progress
        return .running
    }

    mutating func markCommandFinished(currentState: TerminalExecutionState) -> TerminalExecutionState {
        // Shell integration (OSC 133;D) fires on *every* precmd, including
        // empty commands — pressing Enter, Ctrl-C, or Ctrl-L on an idle prompt
        // emits COMMAND_FINISHED with no preceding command. Only treat it as a
        // real completion when a command was actually running; from idle it's
        // precmd noise and must not flip the pane to `.done` (which would
        // persist as a spurious checkmark after restart).
        guard currentState == .running else { return currentState }
        runningSource = nil
        progressQuiesced = nil
        pendingProgressQuiesce = false
        return .done
    }

    mutating func markProgressFinished(currentState: TerminalExecutionState) -> TerminalExecutionState {
        guard hasUserInteraction || runningSource == .progress else { return currentState }
        if let lastForeground {
            progressQuiesced = lastForeground
        } else {
            pendingProgressQuiesce = true
        }
        runningSource = nil
        return currentState == .running ? .done : currentState
    }

    mutating func markTerminalActivity(
        at date: Date,
        currentState: TerminalExecutionState
    ) -> TerminalExecutionState {
        // A render/output heartbeat can keep an already-running command active,
        // but it must never (re)start one. From `.done` — a finished command
        // whose checkmark is showing — output (e.g. a background job) must not
        // flip the pane back to running; only a new foreground process or an
        // explicit progress marker can. Pinned by TerminalExecutionTrackerTests
        // so a refactor of the onTerminalRender closure can't silently
        // reintroduce the "prompt redraw keeps spinning" bug.
        guard currentState != .done else { return currentState }
        guard runningSource != .progress else { return currentState }
        if let progressQuiesced, progressQuiesced == lastForeground { return currentState }
        // Output/render only counts after user interaction (or a declarative
        // `run:`, which seeds `hasUserInteraction`). Fresh/restored shells can
        // emit startup banners or shell-integration redraws before the user does
        // anything; those must not become persisted completion indicators.
        guard hasUserInteraction else { return currentState }
        runningSource = .activity(date)
        return .running
    }

    mutating func settleIfQuiet(
        now: Date,
        quietInterval: TimeInterval,
        currentState: TerminalExecutionState
    ) -> TerminalExecutionState {
        guard currentState == .running,
              case let .activity(lastActivityAt) = runningSource,
              now.timeIntervalSince(lastActivityAt) >= quietInterval
        else { return currentState }
        runningSource = nil
        return .done
    }

    /// Restart the quiet window of an activity-sourced run. Used on the
    /// occluded→visible edge: a parked renderer emits no heartbeats, so the
    /// elapsed silence says nothing about completion — and a false `.done`
    /// would stick, because activity can never revive `.done` (see
    /// `markTerminalActivity`).
    mutating func refreshActivityWindow(now: Date) {
        guard case .activity = runningSource else { return }
        runningSource = .activity(now)
    }

    mutating func refreshForeground(
        name: String?,
        pid: pid_t?,
        foregroundIsShell: Bool,
        terminalInputIsRaw: Bool,
        currentState: TerminalExecutionState
    ) -> TerminalExecutionState {
        let newKey = foregroundIsShell ? nil : ForegroundProcessKey(name: name, pid: pid)

        // Resolve a pending progress quiesce: the first foreground process
        // after a progress race (progress cleared before any poll) is quiesced
        // rather than marked running. A shell arriving first cancels it.
        if pendingProgressQuiesce {
            if let newKey {
                progressQuiesced = newKey
                pendingProgressQuiesce = false
                lastForeground = newKey
                return currentState
            }
            pendingProgressQuiesce = false
        }

        // Drop the quiesce once the foreground moves off the quiesced process.
        if let progressQuiesced, progressQuiesced != newKey {
            self.progressQuiesced = nil
        }

        let changed = newKey != lastForeground
        lastForeground = newKey

        // Foreground returned to the shell: a foreground-running command exited.
        if newKey == nil {
            guard changed, currentState == .running else { return currentState }
            runningSource = nil
            return .done
        }

        // Explicit progress owns the state while active.
        if runningSource == .progress { return currentState }

        // A newly-created/restored plain shell can briefly look like a non-shell
        // foreground while its startup files and shell integration settle. Do
        // not turn that launch noise into a persisted checkmark. Once the user
        // has interacted, foreground transitions are real user work.
        guard hasUserInteraction else { return currentState }

        if terminalInputIsRaw {
            // Raw/cbreak-mode programs (editors, multiplexers, interactive CLIs)
            // should not be held running by foreground alone. If a canonical
            // command switched the tty raw, finish that foreground-only run;
            // activity-sourced runs still quiet-settle normally.
            if currentState == .running, runningSource == .foreground {
                runningSource = nil
                return .done
            }
            return currentState
        }

        // Canonical non-shell command (a build, `sleep`, shell script, …) →
        // running until it returns to the shell. Only act on a change so a
        // settled idle process doesn't flip back to running on every poll.
        guard changed else { return currentState }
        runningSource = .foreground
        return .running
    }
}

/// A pane is the leaf of the split tree — one terminal surface.
@MainActor @Observable
final class Pane: Identifiable {
    let id = UUID()
    let projectPath: String
    let projectID: UUID
    /// Process the pane launches on first surface creation, injected into the
    /// shell as `command + "\n"`. Set from a declarative layout; nil for an
    /// interactively-created pane (plain shell). Recorded here so a layout
    /// `apply` can match a live pane by its declared command even after the
    /// process has exited (see LayoutReconciler).
    let command: String?
    /// Shell binary to launch as the pane's program. nil → resolved from the
    /// ghostty config / login shell at surface-creation time.
    let shell: String?
    /// Extra environment variables for the spawned shell. nil/empty → none.
    let env: [String: String]?
    /// The basename of the pane's live foreground process — a running command
    /// (`hx`, `btop`), or the pane's shell when idle at a prompt (so a nested
    /// `zsh` launched inside `nu` shows `zsh`). nil only before the surface
    /// exists. This is the tab name's default source: it's read from the
    /// process table (`ProcessInspector`), so it's immune to the shell's
    /// prompt-title churn. Refreshed by `refreshForegroundProcess()`.
    var foregroundProcessName: String?

    /// A title a foreground *program* set via OSC 0/2 (claude's session
    /// summary, ssh's `user@host`). When present it wins over
    /// `foregroundProcessName` in `displayTitle`. The escape sequence itself
    /// carries no provenance — a shell that titles from its prompt (nushell,
    /// Starship, ghostty shell-integration — emitting `~/dir`, `host:~/dir`)
    /// is indistinguishable from a program naming its session — so
    /// `receiveReportedTitle` recovers provenance from the process table:
    /// a title is adopted only while the foreground process is NOT a shell,
    /// and it's pinned to that pid — `applyForegroundRefresh` expires it the
    /// moment a different process (usually the shell, on exit) takes the
    /// foreground, so an idle pane falls back to the process name.
    private(set) var programTitle: String?

    /// The foreground pid that set `programTitle`, used to expire it.
    @ObservationIgnored
    private var programTitlePID: pid_t?

    let searchState = TerminalSearchState()
    var executionState: TerminalExecutionState = .idle {
        didSet {
            guard executionState != oldValue else { return }
            // Transitions (idle→running, running→done) are exactly when the
            // adaptive poll should speed up; steady-state assignments and
            // per-frame heartbeats don't reach here (value unchanged).
            NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
        }
    }

    @ObservationIgnored
    private var executionTracker = TerminalExecutionTracker()

    /// Re-read the foreground process name from the process table and publish it
    /// only when it changed (so a steady poll doesn't churn `@Observable` and
    /// re-render the sidebar every tick). Driven by `AppState`'s poll.
    ///
    /// `trackExecution` gates the expensive shell/raw-mode syscalls
    /// (`foregroundProcessIsShell` / `terminalInputIsRaw`) that only feed the
    /// status indicator. Callers on the hot poll pass a precomputed value so
    /// the pref is read once; the default reads `Preferences` for ad-hoc
    /// callers (OSC title, output/progress callbacks) so they stay gated too.
    func refreshForegroundProcess(trackExecution: Bool? = nil) {
        let track = trackExecution ?? Preferences.shared.showTabStatusIndicator
        applyForegroundRefresh(
            name: ProcessInspector.runningProcessName(forPane: self),
            foregroundPID: nsView?.foregroundPID,
            foregroundIsShell: track ? ProcessInspector.foregroundProcessIsShell(forPane: self) : false,
            terminalInputIsRaw: track ? ProcessInspector.terminalInputIsRaw(forPane: self) : false,
            applyExecutionState: track
        )
    }

    /// Testable core of `refreshForegroundProcess`: publish a changed process
    /// name, and expire `programTitle` when the pid that set it no longer
    /// holds the foreground. When `applyExecutionState` is false (the status
    /// indicator is off), the expensive execution-state path is skipped — only
    /// the process name / title provenance update runs.
    func applyForegroundRefresh(
        name: String?,
        foregroundPID: pid_t?,
        foregroundIsShell: Bool = false,
        terminalInputIsRaw: Bool = false,
        applyExecutionState: Bool = true
    ) {
        if name != foregroundProcessName { foregroundProcessName = name }
        if programTitle != nil, programTitlePID != foregroundPID {
            programTitle = nil
            programTitlePID = nil
        }
        guard applyExecutionState else { return }
        applyForegroundExecutionState(
            name: name,
            foregroundPID: foregroundPID,
            foregroundIsShell: foregroundIsShell,
            terminalInputIsRaw: terminalInputIsRaw
        )
    }

    func markCommandRunning() {
        executionState = executionTracker.markProgressStarted(currentState: executionState)
    }

    func markCommandFinished() {
        executionState = executionTracker.markCommandFinished(currentState: executionState)
    }

    func markProgressFinished() {
        executionState = executionTracker.markProgressFinished(currentState: executionState)
    }

    func markTerminalActivity(at date: Date = Date()) {
        executionState = executionTracker.markTerminalActivity(
            at: date,
            currentState: executionState
        )
    }

    func settleTerminalActivityIfQuiet(now: Date = Date(), quietInterval: TimeInterval = 3) {
        executionState = executionTracker.settleIfQuiet(
            now: now,
            quietInterval: quietInterval,
            currentState: executionState
        )
    }

    func refreshTerminalActivityWindow(now: Date = Date()) {
        executionTracker.refreshActivityWindow(now: now)
    }

    @discardableResult
    func acknowledgeCommandCompletion() -> Bool {
        guard executionState == .done else { return false }
        executionState = .idle
        return true
    }

    /// Restore the persisted "done / needs attention" state after a relaunch.
    /// Only the user-visible checkmark is restored; the live tracker starts
    /// idle, so the first real foreground/output signal behaves normally and
    /// a user interaction (or focusing the tab) clears it via
    /// `acknowledgeCommandCompletion`.
    func restoreNeedsAttention() {
        executionState = .done
    }

    func recordUserInteraction() {
        executionTracker.recordUserInteraction()
        acknowledgeCommandCompletion()
        // Keystrokes are the strongest "about to launch something" signal —
        // and the only one available while the non-activating quick terminal
        // has keyboard focus without app focus.
        NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
    }

    private func applyForegroundExecutionState(
        name: String?,
        foregroundPID: pid_t?,
        foregroundIsShell: Bool,
        terminalInputIsRaw: Bool
    ) {
        executionState = executionTracker.refreshForeground(
            name: name,
            pid: foregroundPID,
            foregroundIsShell: foregroundIsShell,
            terminalInputIsRaw: terminalInputIsRaw,
            currentState: executionState
        )
    }

    /// Handle an OSC 0/2 title reported by the surface. Always refreshes the
    /// foreground process (a title arrival is a command boundary); adopts the
    /// string as `programTitle` only when a real program — not the shell — is
    /// in the foreground (see `programTitle` for why).
    func receiveReportedTitle(_ title: String) {
        receiveReportedTitle(title, programPID: ProcessInspector.foregroundProgramPID(forPane: self))
    }

    /// Testable core of `receiveReportedTitle`. `programPID` is the pane's
    /// foreground pid when that process is a non-shell program, nil otherwise.
    func receiveReportedTitle(_ title: String, programPID: pid_t?) {
        // A title arrival is a command boundary — wake the adaptive poll so
        // the other panes' names catch up too.
        NotificationCenter.default.post(name: .terminalPollEvent, object: nil)
        refreshForegroundProcess()
        guard let programPID else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed != programTitle { programTitle = trimmed }
        programTitlePID = programPID
    }

    /// The live terminal NSView for this pane. Created lazily the first time
    /// it's requested, destroyed explicitly when the pane is removed from the
    /// tree. Owning the view on the model (instead of in a separate cache or
    /// inside SwiftUI) keeps the underlying ghostty surface alive across any
    /// SwiftUI view churn: tab switches, split tree reshapes, window hide/show.
    /// Not observed — SwiftUI should never re-render just because this changes.
    @ObservationIgnored
    private var _nsView: GhosttyTerminalNSView?

    func ensureNSView() -> GhosttyTerminalNSView {
        if let existing = _nsView { return existing }
        let view = GhosttyTerminalNSView(workingDirectory: projectPath, command: command, shell: shell, env: env)
        _nsView = view
        return view
    }

    var nsView: GhosttyTerminalNSView? { _nsView }

    /// The `NSScrollView` that hosts this pane's surface and renders the native
    /// overlay scrollbar. Owned here (not by SwiftUI) for the same reason as
    /// `_nsView`: it must survive tab switches and split reshapes, and it
    /// sidesteps Ghostty's #9444 bug where the scroll wrapper isn't persisted.
    @ObservationIgnored
    private var _scrollView: SurfaceScrollView?

    func ensureScrollView() -> SurfaceScrollView {
        if let existing = _scrollView { return existing }
        let scroll = SurfaceScrollView(surfaceView: ensureNSView())
        _scrollView = scroll
        return scroll
    }

    /// Tear down the ghostty surface and null out callbacks. Call when the
    /// pane is removed from the tree. Safe to call multiple times.
    func destroySurface() {
        guard let view = _nsView else { return }
        // Null callbacks before destroy so any in-flight ghostty events
        // triggered by destroySurface() itself can't re-enter.
        view.onProcessExit = nil
        view.onTitleChange = nil
        view.onSearchStart = nil
        view.onSearchEnd = nil
        view.onSearchTotal = nil
        view.onSearchSelected = nil
        view.onFocus = nil
        view.onInteraction = nil
        view.onSplitRequest = nil
        view.onDesktopNotification = nil
        view.onCommandFinished = nil
        view.onProgressStarted = nil
        view.onProgressFinished = nil
        view.onTerminalActivity = nil
        view.onTerminalRender = nil
        view.onScrollbarUpdate = nil
        view.onScrollWheel = nil
        view.destroySurface()
        let scroll = _scrollView
        _scrollView = nil
        _nsView = nil
        // Keep the NSView (and its scroll-view host) alive for a runloop tick so
        // any in-flight ghostty callback (which holds an unretained pointer to
        // the view) can drain before the view is deallocated. Without this,
        // SwiftUI can remove the view from its superview the same turn we
        // destroy the surface, deallocating the NSView before ghostty has
        // finished unwinding.
        DispatchQueue.main.async {
            _ = view
            // Detach the scroll view from whatever still hosts it — notably the
            // SurfaceIncubator's hidden window, which never removes warmed
            // views itself — so the dead view pair can actually deallocate.
            scroll?.removeFromSuperview()
        }
    }

    var processTitle: String {
        // The live foreground process name (`hx`, `btop`) when a program is
        // running, else the shell name when idle. Always process-table derived
        // (never the OSC title) — the quit confirmation lists real process
        // names, and `displayTitle` falls back here.
        if let proc = foregroundProcessName, !proc.isEmpty { return proc }
        return Self.defaultShellName
    }

    /// What the tab/sidebar shows for this pane: a program-reported OSC title
    /// when one is live (see `programTitle`), else the process name.
    var displayTitle: String {
        if let title = programTitle, !title.isEmpty { return title }
        return processTitle
    }

    /// Display fallback for a pane with no foreground process yet (its surface
    /// hasn't been created) — the name of the login shell it will run. Resolves
    /// from the password database (`getpwuid`), the same shell libghostty
    /// launches when no explicit `command` is set. We avoid `$SHELL`: that's the
    /// shell of whatever launched the app (often `/bin/zsh`), not the user's
    /// login shell, so a `nu` user would otherwise see "zsh". Once the surface
    /// is live, `foregroundProcessName` (the actual `comm`) takes over.
    private static let defaultShellName: String = {
        let loginShell = getpwuid(getuid())?.pointee.pw_shell.map { String(cString: $0) }
        let shell = (loginShell?.isEmpty == false ? loginShell : nil)
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
        return (shell as NSString).lastPathComponent
    }()

    var sidebarSegmentTitle: String {
        displayTitle
    }

    init(
        projectPath: String,
        projectID: UUID,
        command: String? = nil,
        shell: String? = nil,
        env: [String: String]? = nil
    ) {
        self.projectPath = projectPath
        self.projectID = projectID
        self.command = command
        self.shell = shell
        self.env = env
        executionTracker = TerminalExecutionTracker(hasUserInteraction: command != nil)
    }
}

/// Recursive split tree. Each leaf is a `Pane`, each branch splits two subtrees.
enum SplitNode: Identifiable {
    case pane(Pane)
    indirect case split(SplitBranch)

    var id: UUID {
        switch self {
        case let .pane(p): p.id
        case let .split(b): b.id
        }
    }
}

@MainActor @Observable
final class SplitBranch: Identifiable {
    let id = UUID()
    var direction: SplitDirection
    var ratio: CGFloat
    var first: SplitNode
    var second: SplitNode

    init(direction: SplitDirection, ratio: CGFloat = 0.5, first: SplitNode, second: SplitNode) {
        self.direction = direction
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}

// MARK: - Tree operations

@MainActor
extension SplitNode {
    func splitting(
        paneID: UUID,
        direction: SplitDirection,
        position: SplitPosition,
        projectPath: String,
        projectID: UUID
    ) -> (node: SplitNode, newPaneID: UUID?) {
        switch self {
        case let .pane(p) where p.id == paneID:
            let newPane = Pane(projectPath: projectPath, projectID: projectID)
            let first: SplitNode = position == .first ? .pane(newPane) : .pane(p)
            let second: SplitNode = position == .first ? .pane(p) : .pane(newPane)
            return (.split(SplitBranch(direction: direction, first: first, second: second)), newPane.id)
        case .pane:
            return (self, nil)
        case let .split(branch):
            let (newFirst, id1) = branch.first.splitting(
                paneID: paneID,
                direction: direction,
                position: position,
                projectPath: projectPath,
                projectID: projectID
            )
            branch.first = newFirst
            if id1 != nil { return (.split(branch), id1) }
            let (newSecond, id2) = branch.second.splitting(
                paneID: paneID,
                direction: direction,
                position: position,
                projectPath: projectPath,
                projectID: projectID
            )
            branch.second = newSecond
            return (.split(branch), id2)
        }
    }

    /// Insert an existing pane next to the pane `destinationID`, wrapping the
    /// destination in a new split with `pane` at `position`. The structural
    /// counterpart of `splitting`, used to re-attach a pane during a
    /// drag-and-drop move. Returns `inserted: false` (tree unchanged) when the
    /// destination isn't in the tree.
    func inserting(
        pane: Pane,
        at destinationID: UUID,
        direction: SplitDirection,
        position: SplitPosition
    ) -> (node: SplitNode, inserted: Bool) {
        switch self {
        case let .pane(p) where p.id == destinationID:
            let first: SplitNode = position == .first ? .pane(pane) : .pane(p)
            let second: SplitNode = position == .first ? .pane(p) : .pane(pane)
            return (.split(SplitBranch(direction: direction, first: first, second: second)), true)
        case .pane:
            return (self, false)
        case let .split(branch):
            let (newFirst, ok1) = branch.first.inserting(
                pane: pane, at: destinationID, direction: direction, position: position
            )
            branch.first = newFirst
            if ok1 { return (.split(branch), true) }
            let (newSecond, ok2) = branch.second.inserting(
                pane: pane, at: destinationID, direction: direction, position: position
            )
            branch.second = newSecond
            return (.split(branch), ok2)
        }
    }

    func removing(paneID: UUID) -> SplitNode? {
        switch self {
        case let .pane(p) where p.id == paneID: return nil
        case .pane: return self
        case let .split(branch):
            if case let .pane(p) = branch.first, p.id == paneID { return branch.second }
            if case let .pane(p) = branch.second, p.id == paneID { return branch.first }
            if branch.first.contains(paneID: paneID), let n = branch.first.removing(paneID: paneID) {
                branch.first = n
                return .split(branch)
            }
            if branch.second.contains(paneID: paneID), let n = branch.second.removing(paneID: paneID) {
                branch.second = n
                return .split(branch)
            }
            return self
        }
    }

    func contains(paneID: UUID) -> Bool {
        switch self {
        case let .pane(p): p.id == paneID
        case let .split(b): b.first.contains(paneID: paneID) || b.second.contains(paneID: paneID)
        }
    }

    func allPanes() -> [Pane] {
        switch self {
        case let .pane(p): [p]
        case let .split(b): b.first.allPanes() + b.second.allPanes()
        }
    }

    func findPane(id: UUID) -> Pane? {
        switch self {
        case let .pane(p): p.id == id ? p : nil
        case let .split(b): b.first.findPane(id: id) ?? b.second.findPane(id: id)
        }
    }

    func paneFrames(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [UUID: CGRect] {
        switch self {
        case let .pane(p):
            return [p.id: rect]
        case let .split(b):
            let r = min(max(b.ratio, 0), 1)
            if b.direction == .horizontal {
                let w1 = rect.width * r
                let r1 = CGRect(x: rect.minX, y: rect.minY, width: w1, height: rect.height)
                let r2 = CGRect(x: rect.minX + w1, y: rect.minY, width: rect.width - w1, height: rect.height)
                return b.first.paneFrames(in: r1).merging(b.second.paneFrames(in: r2)) { a, _ in a }
            }
            let h1 = rect.height * r
            let r1 = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h1)
            let r2 = CGRect(x: rect.minX, y: rect.minY + h1, width: rect.width, height: rect.height - h1)
            return b.first.paneFrames(in: r1).merging(b.second.paneFrames(in: r2)) { a, _ in a }
        }
    }

    /// Find the nearest pane in a direction from the currently focused pane.
    func nearestPane(from focusedID: UUID, direction: PaneFocusDirection) -> UUID? {
        let frames = paneFrames()
        guard let focusedFrame = frames[focusedID] else { return nil }
        var bestID: UUID?
        var bestDist: CGFloat = .greatestFiniteMagnitude
        for (id, frame) in frames where id != focusedID {
            let isCandidate: Bool = switch direction {
            case .left: frame.midX < focusedFrame.midX && frame.maxY > focusedFrame.minY && frame.minY < focusedFrame.maxY
            case .right: frame.midX > focusedFrame.midX && frame.maxY > focusedFrame.minY && frame.minY < focusedFrame.maxY
            case .up: frame.midY < focusedFrame.midY && frame.maxX > focusedFrame.minX && frame.minX < focusedFrame.maxX
            case .down: frame.midY > focusedFrame.midY && frame.maxX > focusedFrame.minX && frame.minX < focusedFrame.maxX
            }
            guard isCandidate else { continue }
            let dist: CGFloat = switch direction {
            case .left,
                 .right: abs(focusedFrame.midX - frame.midX)
            case .up,
                 .down: abs(focusedFrame.midY - frame.midY)
            }
            if dist < bestDist { bestDist = dist
                bestID = id
            }
        }
        return bestID
    }
}

enum PaneFocusDirection { case left, right, up, down }

@MainActor
extension SplitNode {
    /// Rebalance all ratios so sibling panes along each direction share space
    /// evenly. Mutates in place; returns the receiver for chaining.
    @discardableResult
    func rebalanced() -> SplitNode {
        if case let .split(branch) = self {
            let leftUnits = branch.first.tileUnits(along: branch.direction)
            let rightUnits = branch.second.tileUnits(along: branch.direction)
            let total = leftUnits + rightUnits
            if total > 0 {
                branch.ratio = CGFloat(leftUnits) / CGFloat(total)
            }
            _ = branch.first.rebalanced()
            _ = branch.second.rebalanced()
        }
        return self
    }

    /// Number of "cells" this subtree contributes when laid out along the given
    /// direction. Same-direction descendants expand to their leaf count;
    /// different-direction or leaf nodes count as a single cell.
    private func tileUnits(along direction: SplitDirection) -> Int {
        switch self {
        case .pane: 1
        case let .split(b):
            b.direction == direction
                ? b.first.tileUnits(along: direction) + b.second.tileUnits(along: direction)
                : 1
        }
    }

    /// Adjust the ratio of the nearest ancestor split in the given direction by `delta`.
    /// Returns the receiver if no matching split is found.
    func resizing(paneID: UUID, direction: PaneFocusDirection, delta: CGFloat) -> SplitNode {
        let axis: SplitDirection = (direction == .left || direction == .right) ? .horizontal : .vertical
        let sign: CGFloat = (direction == .right || direction == .down) ? 1 : -1
        _ = applyResize(paneID: paneID, axis: axis, delta: sign * delta)
        return self
    }

    /// Walks the tree and applies the delta to the closest matching-axis ancestor
    /// of the given pane. Returns true if the ratio was actually adjusted.
    @discardableResult
    private func applyResize(paneID: UUID, axis: SplitDirection, delta: CGFloat) -> Bool {
        guard case let .split(branch) = self else { return false }
        let firstHas = branch.first.contains(paneID: paneID)
        let secondHas = branch.second.contains(paneID: paneID)
        guard firstHas || secondHas else { return false }
        // Recurse first — deeper (closer) ancestor wins.
        let child: SplitNode = firstHas ? branch.first : branch.second
        if child.applyResize(paneID: paneID, axis: axis, delta: delta) { return true }
        // No deeper match; if this branch matches the axis, apply here.
        if branch.direction == axis {
            branch.ratio = min(max(branch.ratio + delta, 0.15), 0.85)
            return true
        }
        return false
    }
}
