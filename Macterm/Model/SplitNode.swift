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

    /// Re-read the foreground process name from the process table and publish it
    /// only when it changed (so a steady poll doesn't churn `@Observable` and
    /// re-render the sidebar every tick). Driven by `AppState`'s poll.
    func refreshForegroundProcess() {
        applyForegroundRefresh(
            name: ProcessInspector.runningProcessName(forPane: self),
            foregroundPID: nsView?.foregroundPID
        )
    }

    /// Testable core of `refreshForegroundProcess`: publish a changed process
    /// name, and expire `programTitle` when the pid that set it no longer
    /// holds the foreground.
    func applyForegroundRefresh(name: String?, foregroundPID: pid_t?) {
        if name != foregroundProcessName { foregroundProcessName = name }
        if programTitle != nil, programTitlePID != foregroundPID {
            programTitle = nil
            programTitlePID = nil
        }
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
        view.onSplitRequest = nil
        view.onDesktopNotification = nil
        view.onCommandFinished = nil
        view.onScrollbarUpdate = nil
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
