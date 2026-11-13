import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var paneHostID: UUID?
}

struct TerminalPane: View {
    let pane: Pane
    let focused: Bool
    let isZoomed: Bool
    let isSplit: Bool
    /// Dimmed because another pane drives this session's size (#345).
    var isNonLeaderMirror = false
    let onFocus: () -> Void
    let onProcessExit: () -> Void
    let onCommandFinished: () -> Void
    let onAdaptiveBackgroundChange: (CGColor?) -> Void
    let onSplitRequest: (SplitDirection, SplitPosition) -> Void
    let onZoomRequest: () -> Void
    @Environment(AppState.self)
    private var appState: AppState?
    @Environment(\.paneHostID)
    private var hostID

    var body: some View {
        // This window's view of the pane: its own search, copy mode and
        // read-only state, its own view, its own client of the session.
        let surface = pane.surface(for: hostID)
        // The search bar sits above the terminal surface in a VStack, so showing
        // it pushes the terminal content down rather than overlaying it.
        VStack(spacing: 0) {
            if surface.searchState.isVisible {
                TerminalSearchBar(
                    searchState: surface.searchState,
                    onNavigateNext: { surface.nsView?.navigateSearch(direction: .next) },
                    onNavigatePrevious: { surface.nsView?.navigateSearch(direction: .previous) },
                    onClose: {
                        guard let view = surface.nsView else { return }
                        view.endSearch()
                        // Return focus to the terminal so typing resumes without
                        // a click. Closing the search bar removes it from the
                        // VStack — a reshape — so route through FocusRestoration
                        // rather than a bare makeFirstResponder that races the
                        // NSView's window re-attachment.
                        FocusRestoration.restoreFocus(to: pane.id, finder: { pane }, in: view.window)
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            TerminalSurface(
                pane: pane,
                surface: surface,
                focused: focused,
                isZoomed: isZoomed,
                isSplit: isSplit,
                isNonLeaderMirror: isNonLeaderMirror,
                // Read here (not just passed through) so the observation
                // dependency registers: an orphaned-with-no-host bump must
                // re-render this subtree — see PaneSurface.reattachTick.
                reattachTick: surface.reattachTick,
                onFocus: onFocus,
                onProcessExit: onProcessExit,
                onCommandFinished: onCommandFinished,
                onAdaptiveBackgroundChange: onAdaptiveBackgroundChange,
                onSplitRequest: onSplitRequest,
                onZoomRequest: onZoomRequest
            )
            // Overlays anchor to the surface, not the VStack, so the search
            // bar (above) never shifts them.
            .overlay(alignment: .bottomLeading) {
                if let url = surface.hoverURL {
                    LinkHoverBanner(url: url)
                }
            }
            .overlay(alignment: .topTrailing) {
                // The pane's badges, one row in the trailing corner, in this
                // order from the left: Read-Only, Copy Mode, Zoomed, then the
                // lock. The Zoomed pill is here too, not on the tab: a zoomed
                // pane is the only pane on screen, and one row cannot overlap
                // itself.
                HStack(spacing: 6) {
                    // Read-Only pill: libghostty sends no input to the pty.
                    // A click turns read-only off.
                    if surface.isReadOnly {
                        ModePill(
                            title: String(localized: "Read-Only"),
                            systemImage: "eye",
                            help: String(localized: "Turn off read-only")
                        ) { [weak surface] in
                            surface?.nsView?.sendBindingAction("toggle_readonly")
                        }
                    }
                    // Copy-mode pill: the pane's keys move the selection, not
                    // the shell. The Zoomed pill's chrome, since both are
                    // modes that one click leaves. Per pane, since the mode is.
                    if let label = surface.copyModeLabel {
                        ModePill(
                            title: label,
                            systemImage: "character.cursor.ibeam",
                            help: String(localized: "Leave copy mode")
                        ) { [weak surface] in
                            surface?.nsView?.copyMode.exit()
                        }
                    }
                    // Outdated-session pill: the session runs from an older
                    // Macterm version. A click restarts it, and asks first
                    // when a program runs.
                    if let appState, appState.showsOutdatedSessionBadge(pane) {
                        ModePill(
                            title: String(localized: "Outdated"),
                            systemImage: "arrow.triangle.2.circlepath",
                            help: String(localized: "Some panes in this tab are from an outdated Macterm version")
                        ) { [weak appState, weak pane] in
                            guard let appState, let pane else { return }
                            appState.requestRestartSession(of: pane)
                        }
                    }
                    if isZoomed {
                        ZoomIndicator(onExit: onZoomRequest)
                            .transition(.opacity)
                    }
                    // Secure-input badge: the OS is shielding keystrokes for
                    // this pane's password prompt (or the global toggle).
                    // Focus-scoped, so at most one pane shows it.
                    if focused, SecureInput.shared.enabled, GhosttyApp.shared.secureInputIndication {
                        SecureInputBadge()
                    }
                }
                .padding(8)
            }
        }
        .background {
            if let color = surface.adaptiveBackgroundColor {
                Color(cgColor: color)
            }
        }
    }
}

/// Safari-style link preview shown while the mouse hovers an OSC 8 / detected
/// URL in the terminal (`GHOSTTY_ACTION_MOUSE_OVER_LINK`). Invisible and
/// bidirectional characters are spelled out (`UntrustedURL`), so an OSC 8
/// target can't show as something it isn't.
private struct LinkHoverBanner: View {
    let url: String

    var body: some View {
        Text(verbatim: UntrustedURL.escapingUnsafeCharacters(url))
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(MactermTheme.fgMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(MactermTheme.bg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MactermTheme.border))
            .frame(maxWidth: 480, alignment: .leading)
            .padding(6)
            .allowsHitTesting(false)
    }
}

/// Lock badge shown while secure keyboard input is active for the focused
/// pane (`macos-secure-input-indication`).
private struct SecureInputBadge: View {
    var body: some View {
        Image(systemName: "lock.fill")
            .font(.caption)
            .foregroundStyle(MactermTheme.fgMuted)
            .padding(5)
            .background(MactermTheme.bg, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(MactermTheme.border))
            .allowsHitTesting(false)
            .help("Secure keyboard input is active")
    }
}

/// The real terminal NSView, hosted via NSViewRepresentable.
/// The NSView itself is owned by `Pane` — this representable just returns the
/// stored instance so SwiftUI lifecycle events (tab switches, split reshapes)
/// don't destroy the underlying ghostty surface.
private struct TerminalSurface: NSViewRepresentable {
    let pane: Pane
    let surface: PaneSurface
    let focused: Bool
    let isZoomed: Bool
    let isSplit: Bool
    /// Another pane drives this session's pty size (#345), so this surface's
    /// frame is laid out for foreign geometry.
    let isNonLeaderMirror: Bool
    /// Changes force `updateNSView` after an orphaned-with-no-host event.
    let reattachTick: Int
    let onFocus: () -> Void
    let onProcessExit: () -> Void
    let onCommandFinished: () -> Void
    let onAdaptiveBackgroundChange: (CGColor?) -> Void
    let onSplitRequest: (SplitDirection, SplitPosition) -> Void
    let onZoomRequest: () -> Void

    /// Optional on purpose: the quick terminal's hosting view has no AppState
    /// in its environment, and its one tab has no rename UI anyway — the
    /// tab-title actions just no-op there.
    @Environment(AppState.self) private var appState: AppState?
    /// Optional for the same reason; only a clicked file link reads it, for
    /// the project directory a split or tab starts in.
    @Environment(ProjectStore.self) private var projectStore: ProjectStore?

    final class Coordinator {
        var wasFocused = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Dumb container SwiftUI owns outright. The pane's shared scroll view is
    /// OUR subview of it, re-parented explicitly — never handed to SwiftUI as
    /// the representable's view itself. Handing it over directly broke on
    /// drag-and-drop reorders (#227): a tree reshape remounts the split view,
    /// SwiftUI builds the new hierarchy (adopting the shared NSView) BEFORE
    /// tearing down the old one, and the old teardown then yanks the view out
    /// of its NEW superview — the pane went blank, teardown-order dependent.
    /// With a disposable container per representable identity, a late yank
    /// only ever kills an empty container, and `attach` re-asserts parentage.
    /// The host also claims the scroll view when IT enters the window — the
    /// scroll-side orphan heal is window-gated, so without this trigger an
    /// orphaning that lands before the new host is windowed stayed blank
    /// until the next `updateNSView`.
    final class SurfaceHost: NSView {
        weak var scroll: SurfaceScrollView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Claim UNCONDITIONALLY (and correct `reattachHost`): SwiftUI can
            // create several transient hosts for one pane during a remount,
            // and the order of make/update calls says nothing about which
            // one survives. Landing in the window is the survival signal —
            // discarded hosts never get here.
            guard window != nil, let scroll else { return }
            scroll.reattachHost = self
            scroll.adopt(into: self)
        }
    }

    func makeNSView(context: Context) -> SurfaceHost {
        let host = SurfaceHost()
        let scroll = surface.ensureScrollView()
        attach(scroll, to: host)
        let view = scroll.surfaceView
        configure(view)
        // Defer surface creation until the view is actually in a window — the
        // Metal layer needs a non-zero size to initialize. The re-attach also
        // runs after the whole SwiftUI transaction, so it repairs the
        // teardown-order yank described on `SurfaceHost`.
        DispatchQueue.main.async { [surface] in
            attach(scroll, to: host)
            if view.surface == nil, view.window != nil {
                view.createSurface()
            }
            if focused {
                AdaptiveTerminalChrome.shared.focusDidChange(to: view)
                // Not `in: view.window`: the host may not be in the window yet
                // (see restoreFocusWhenAttached).
                FocusRestoration.restoreFocusWhenAttached(surface)
            }
        }
        context.coordinator.wasFocused = focused
        return host
    }

    /// Re-parent the pane's shared scroll view into `host` (idempotent). Also
    /// covers the `SurfaceIncubator` case — the pane may have been warmed in a
    /// never-shown window, and a view can't live in two superviews. Skipped
    /// while `host` is off-window so a dying container can't steal the view.
    private func attach(_ scroll: SurfaceScrollView, to host: SurfaceHost) {
        host.scroll = scroll
        scroll.onOrphaned = { [weak surface] in surface?.requestReattach() }
        // Adopt (and point `reattachHost` at this host) only when the host is
        // already in the window, or the scroll has no home at all. A host
        // that is off-window while the scroll lives elsewhere must NOT
        // redirect `reattachHost`: SwiftUI creates transient extra hosts
        // during a remount and the last make/update is not necessarily the
        // survivor — the survivor claims the scroll (and corrects the
        // pointer) in `SurfaceHost.viewDidMoveToWindow`.
        guard host.window != nil || scroll.superview == nil else { return }
        scroll.reattachHost = host
        scroll.adopt(into: host)
    }

    func updateNSView(_ host: SurfaceHost, context: Context) {
        let scroll = surface.ensureScrollView()
        attach(scroll, to: host)
        let view = scroll.surfaceView
        configure(view)

        // Create the surface now if it's still pending (e.g. the view was
        // added to the window after first makeNSView).
        if view.surface == nil, view.window != nil {
            view.createSurface()
        }

        let wasFocused = context.coordinator.wasFocused
        context.coordinator.wasFocused = focused
        view.isFocused = focused
        view.rendersForeignGeometry = isNonLeaderMirror
        if focused, !wasFocused {
            AdaptiveTerminalChrome.shared.focusDidChange(to: view)
            view.notifySurfaceFocused()
            // The user is looking at this pane now, so any banner still sitting
            // in Notification Center for it is stale. Same point Ghostty clears
            // a surface's notifications — and its bell — from (`focusDidChange`).
            NotificationHandler.shared.clearDelivered(paneID: pane.id)
            pane.acknowledgeBell()
            FocusRestoration.restoreFocusWhenAttached(surface)
        } else if !focused, wasFocused {
            view.notifySurfaceUnfocused()
        }
    }

    static func dismantleNSView(_ host: SurfaceHost, coordinator _: Coordinator) {
        // Intentionally empty. Only the disposable container dies here; the
        // scroll view and its surface are owned by `Pane`, and when the pane
        // is removed from the tree AppState calls pane.destroySurface()
        // explicitly.
        _ = host
    }

    /// The callbacks that need this window's inputs. The pane connects the
    /// rest when it makes the view (`Pane.connectViewCallbacks`), so they
    /// work before any window draws it.
    private func configure(_ view: GhosttyTerminalNSView) {
        view.onFocus = onFocus
        // Every surface of the pane gets the session's exit. Only the feed's
        // ends the pane: another window's client that dies alone is a detach.
        view.onProcessExit = { [weak surface] in
            if surface?.isFeed ?? true { onProcessExit() }
        }
        view.onSplitRequest = onSplitRequest
        view.onZoomRequest = onZoomRequest
        view.isZoomed = isZoomed
        view.isSplit = isSplit
        view.isFocused = focused
        view.rendersForeignGeometry = isNonLeaderMirror
        // A run ended: the window acknowledges it if the user looks at the pane.
        view.onRunEnded = onCommandFinished
        view.onOpenLink = { [weak appState, weak projectStore, weak pane] text in
            // The quick terminal's and desktop widgets' hosting views carry
            // no environment, and their clicks need the app's state too.
            let delegate = QuickTerminalService.shared.appDelegate
            guard let pane, let state = appState ?? delegate?.appState else { return false }
            let projects = (projectStore ?? delegate?.projectStore)?.projects ?? []
            return state.openClickedLink(text, in: pane, projects: projects)
        }
        view.onPromptTitle = { [weak appState, weak pane] in
            guard let pane else { return }
            appState?.renameTab(containing: pane.id, projectID: pane.projectID)
        }
        view.onSetTabTitle = { [weak appState, weak pane] title in
            guard let pane else { return }
            appState?.setTabTitle(containing: pane.id, projectID: pane.projectID, title: title)
        }
        view.onAdaptiveBackgroundChange = { color in
            let resolved = color?.usingColorSpace(.sRGB)?.cgColor
            onAdaptiveBackgroundChange(resolved)
        }
    }
}
