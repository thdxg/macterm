import CoreGraphics
import Foundation

/// One window's view of one pane: a libghostty view, its scroll view and the
/// UI state that belongs to that view alone (search, copy mode, read-only,
/// hover link, adaptive background, closing ghost).
///
/// The `Pane` is the record: its identity, its session and the runtime state
/// that the session's output decides (titles, foreground, run state, bells).
/// A pane has one surface for each window that draws it, so two windows on one
/// tab show the same pane ids and each has its own view and its own client on
/// the session.
///
/// A surface starts with no window (`windowID == nil`): the incubator, the CLI
/// and the quick terminal get it so. The first window that draws the pane
/// takes it (`Pane.surface(for:)`).
@MainActor @Observable
final class PaneSurface: Identifiable {
    let id = UUID()
    @ObservationIgnored
    unowned let pane: Pane
    /// The window that draws this surface; nil until one does.
    @ObservationIgnored
    fileprivate(set) var windowID: UUID?

    let searchState = TerminalSearchState()
    /// What the copy-mode pill says (`Copy Mode`, `Select Mode`), nil while the
    /// mode is off. The view's `CopyModeController` owns the mode and reports
    /// it here. Live UI state only — never persisted.
    var copyModeLabel: String?
    /// The surface is read-only (ghostty's `toggle_readonly`): libghostty sends
    /// no input to the pty. Drives the Read-Only pill. A new surface starts
    /// writable, so `destroy` clears it. Live UI state only.
    var isReadOnly = false
    /// Temporary full-pane fill used when a TUI owns this leaf's background in
    /// a split. Presentation only, never persisted, and a CGColor so the model
    /// stays independent of AppKit and SwiftUI.
    var adaptiveBackgroundColor: CGColor?
    /// The OSC 8 link URL under the mouse, for the hover banner
    /// (`GHOSTTY_ACTION_MOUSE_OVER_LINK`). Live UI state only.
    var hoverURL: String?
    /// Bumped when the scroll view finds itself orphaned with no living
    /// container to heal into (#227 — SwiftUI can deallocate a transient
    /// container outright, killing the weak re-attach pointer).
    /// `TerminalPane` reads this, so a bump re-renders the pane's subtree and
    /// `TerminalSurface.updateNSView` re-attaches on a container SwiftUI
    /// guarantees is alive.
    var reattachTick = 0

    func requestReattach() {
        reattachTick &+= 1
    }

    init(pane: Pane, windowID: UUID?) {
        self.pane = pane
        self.windowID = windowID
    }

    /// The window takes a surface that no window had yet.
    fileprivate func claim(for windowID: UUID) {
        self.windowID = windowID
    }

    /// Whether this surface's runtime callbacks feed the pane: the first
    /// surface of the pane. Every surface parses the same output, so only one
    /// may count titles, runs, bells and notifications.
    var isFeed: Bool { pane.surfaces.first === self }

    /// The live terminal NSView. Created lazily the first time it's requested,
    /// destroyed explicitly with the pane or when its window goes. Owning the
    /// view here (not in a cache or inside SwiftUI) keeps the underlying
    /// ghostty surface alive across any SwiftUI view churn: tab switches,
    /// split tree reshapes, window hide/show. Not observed.
    @ObservationIgnored
    private var _nsView: GhosttyTerminalNSView?

    var nsView: GhosttyTerminalNSView? { _nsView }

    func ensureNSView() -> GhosttyTerminalNSView {
        if let existing = _nsView { return existing }
        let view = pane.makeView()
        view.owningPane = pane
        view.owningSurface = self
        _nsView = view
        connectUICallbacks(view)
        pane.connectViewCallbacks(view, isFeed: isFeed)
        MactermPaneEntity.annotate(view, for: pane)
        return view
    }

    /// The `NSScrollView` that hosts the surface and renders the native
    /// overlay scrollbar. Owned here (not by SwiftUI) for the same reason as
    /// `_nsView`: it must survive tab switches and split reshapes, and it
    /// sidesteps Ghostty's #9444 bug where the scroll wrapper isn't persisted.
    @ObservationIgnored
    private var _scrollView: SurfaceScrollView?

    var scrollView: SurfaceScrollView? { _scrollView }

    func ensureScrollView() -> SurfaceScrollView {
        if let existing = _scrollView { return existing }
        let scroll = SurfaceScrollView(surfaceView: ensureNSView())
        _scrollView = scroll
        return scroll
    }

    /// The surface's last frame, taken as it was torn down, for the animated
    /// split layout to slide out in its place (`AnimatedSplitView` ghosts).
    /// Only the model can take it: by the time SwiftUI sees the pane leave the
    /// tree the view is gone. Captured only while `Preferences.animatedSplits`
    /// is on, so the default path pays nothing. Set with a nil image when the
    /// surface never drew, which still marks the pane as closed rather than
    /// merely moved to another tab.
    @ObservationIgnored
    private(set) var closingSnapshot: PanePreview?

    /// Take `closingSnapshot` now, for a pane that leaves the tree whose
    /// surface is torn down later. `destroy` calls it too.
    func captureClosingSnapshot() {
        if Preferences.shared.animatedSplits, closingSnapshot == nil, _nsView != nil {
            closingSnapshot = PanePreviewCapture.capture(self, longEdge: nil, fillsBackground: false)
        }
    }

    /// The callbacks that belong to this view alone: search, copy mode, the
    /// hover link and read-only. Every surface of a pane gets them.
    private func connectUICallbacks(_ view: GhosttyTerminalNSView) {
        view.copyMode.onLabelChange = { [weak self] label in self?.copyModeLabel = label }
        view.onSearchStart = { [weak self, weak view] needle in
            guard let self else { return }
            // Cmd+F toggles: if the search bar is already open, a second
            // start_search closes it (and returns focus to the terminal),
            // mirroring the close button rather than re-opening.
            if searchState.isVisible {
                guard let view else { return }
                view.endSearch()
                // Closing the search bar is a reshape — route focus through
                // FocusRestoration, not a bare makeFirstResponder (see onClose).
                FocusRestoration.restoreFocus(to: pane.id, finder: { [weak self] in self?.pane }, in: view.window)
                return
            }
            if let needle, !needle.isEmpty { searchState.needle = needle }
            searchState.isVisible = true
            searchState.startPublishing { [weak self, weak view] q in
                view?.sendSearchQuery(q)
                // The tick scan must run against the needle the core actually
                // searched, not the live (possibly newer) field text.
                self?.scrollView?.noteSearchNeedle(q)
            }
            if !searchState.needle.isEmpty { searchState.pushNeedle() }
        }
        view.onSearchEnd = { [weak self] in
            guard let self else { return }
            searchState.stopPublishing()
            searchState.isVisible = false
            searchState.needle = ""
            searchState.total = nil
            searchState.selected = nil
            scrollView?.clearSearchTicks()
        }
        view.onSearchTotal = { [weak self] total in
            guard let self else { return }
            searchState.total = total
            if total == nil {
                scrollView?.clearSearchTicks()
            } else {
                scrollView?.refreshSearchTicks()
            }
        }
        view.onSearchSelected = { [weak self] sel in
            self?.searchState.selected = sel
            self?.scrollView?.setSearchSelected(sel)
        }
        view.onLinkHover = { [weak self] url in
            self?.hoverURL = url
        }
        view.onReadOnlyChange = { [weak self] isReadOnly in
            self?.isReadOnly = isReadOnly
        }
    }

    /// Tear down the ghostty surface and null out callbacks. Safe to call
    /// more than once.
    func destroy() {
        captureClosingSnapshot()
        guard let view = _nsView else { return }
        // Null callbacks before destroy so any in-flight ghostty events
        // triggered by destroySurface() itself can't re-enter.
        view.onProcessExit = nil
        view.onBell = nil
        view.onTitleChange = nil
        view.onSearchStart = nil
        view.onSearchEnd = nil
        view.onSearchTotal = nil
        view.onSearchSelected = nil
        view.onFocus = nil
        view.onInteraction = nil
        view.onCommandSubmitted = nil
        view.onSplitRequest = nil
        view.onOpenLink = nil
        view.onDesktopNotification = nil
        view.onCommandFinished = nil
        view.onProgressStarted = nil
        view.onProgressFinished = nil
        view.onRunEnded = nil
        view.onTerminalRender = nil
        view.onBackgroundColorChange = nil
        view.onAdaptiveBackgroundChange = nil
        view.onOutputActivity = nil
        view.onSnapshotMark = nil
        view.onRemoteForeground = nil
        view.onScrollbarUpdate = nil
        view.onLinkHover = nil
        view.onReadOnlyChange = nil
        isReadOnly = false
        view.onMouseShapeChange = nil
        view.onPromptTitle = nil
        view.onSetTabTitle = nil
        view.titleProvider = nil
        // Release any secure-input scope this view holds (a pane closed
        // mid-password-prompt must not leave the OS state stuck on).
        view.passwordInput = false
        view.detectedPasswordInput = false
        // Drop any prompt, pending save or bubble this view anchors — a
        // captured password must not outlive its pane.
        PasswordPromptMonitor.shared.forget(view)
        view.destroySurface()
        let scroll = _scrollView
        // Disarm the orphan-healing re-attach BEFORE the removal below —
        // otherwise a destroyed pane would climb back into its old container.
        scroll?.reattachHost = nil
        scroll?.onOrphaned = nil
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
}

extension Pane {
    /// The surface of `windowID`, if the pane has one. Makes nothing.
    func existingSurface(for windowID: UUID?) -> PaneSurface? {
        guard let windowID else { return surfaces[0] }
        return surfaces.first { $0.windowID == windowID }
    }

    /// The surface that `window` draws this pane with. The first window to ask
    /// takes the surface that no window has (the incubator's, the CLI's);
    /// every other window gets a surface of its own, which is a second client
    /// of the same session. `nil` is the host of the quick terminal, the
    /// desktop widgets and the incubator: it gets the first surface.
    ///
    /// Makes only the model object. No view and no client exist until the
    /// surface's `ensureNSView`, so a body may call it.
    func surface(for windowID: UUID?) -> PaneSurface {
        guard let windowID else { return surfaces[0] }
        if let existing = surfaces.first(where: { $0.windowID == windowID }) { return existing }
        if let free = surfaces.first(where: { $0.windowID == nil }) {
            free.claim(for: windowID)
            return free
        }
        let surface = PaneSurface(pane: self, windowID: windowID)
        surfaces.append(surface)
        return surface
    }

    /// The surface the pane's CLI verbs, session queries and previews use: the
    /// one in the key window, else one in a visible window, else the first
    /// that has a view, else the first.
    var preferredSurface: PaneSurface {
        let live = surfaces.filter { $0.nsView != nil }
        return live.first { $0.nsView?.window?.isKeyWindow == true }
            ?? live.first { $0.nsView?.window?.isVisible == true }
            ?? live.first
            ?? surfaces[0]
    }

    /// Give up the surfaces of `windowID`. A pane keeps its last surface, which
    /// has no window afterwards, so a warm view survives a closed window.
    func releaseSurfaces(of windowID: UUID) {
        for surface in surfaces where surface.windowID == windowID {
            if surfaces.count == 1 {
                surface.windowID = nil
            } else {
                retire(surface)
            }
        }
    }

    /// Destroy and drop one surface while another remains. A client that goes
    /// ends only its own channel: the session is the pane's, never the
    /// surface's. When the first surface goes, the next one becomes the feed
    /// and takes over the runtime callbacks.
    func retire(_ surface: PaneSurface) {
        guard surfaces.count > 1, let index = surfaces.firstIndex(where: { $0 === surface }) else { return }
        surface.captureClosingSnapshot()
        surfaces.remove(at: index)
        if index == 0 {
            // The old feed may have gone between the two snapshot marks.
            receiveRemoteSnapshot(started: false)
            if let view = surfaces[0].nsView { connectViewCallbacks(view, isFeed: true) }
        }
        // Deferred: a retire can come from inside a SwiftUI update while the
        // view is still in a hierarchy.
        DispatchQueue.main.async { surface.destroy() }
    }
}
