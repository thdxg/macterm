import AppKit
import SwiftUI
import UserNotifications

struct TerminalPane: View {
    let pane: Pane
    let focused: Bool
    let isZoomed: Bool
    let onFocus: () -> Void
    let onProcessExit: () -> Void
    let onCommandFinished: () -> Void
    let onAdaptiveBackgroundChange: (CGColor?) -> Void
    let onSplitRequest: (SplitDirection, SplitPosition) -> Void
    let onZoomRequest: () -> Void

    var body: some View {
        // The search bar sits above the terminal surface in a VStack, so showing
        // it pushes the terminal content down rather than overlaying it.
        VStack(spacing: 0) {
            if pane.searchState.isVisible {
                TerminalSearchBar(
                    searchState: pane.searchState,
                    onNavigateNext: { pane.nsView?.navigateSearch(direction: .next) },
                    onNavigatePrevious: { pane.nsView?.navigateSearch(direction: .previous) },
                    onClose: {
                        guard let view = pane.nsView else { return }
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
                focused: focused,
                isZoomed: isZoomed,
                // Read here (not just passed through) so the observation
                // dependency registers: an orphaned-with-no-host bump must
                // re-render this subtree — see Pane.surfaceReattachTick.
                reattachTick: pane.surfaceReattachTick,
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
                if let url = pane.hoverURL {
                    LinkHoverBanner(url: url)
                }
            }
            .overlay(alignment: .topTrailing) {
                // Secure-input badge: the OS is shielding keystrokes for this
                // pane's password prompt (or the global toggle). Focus-scoped,
                // so at most one pane shows it.
                if focused, SecureInput.shared.enabled, GhosttyApp.shared.secureInputIndication {
                    SecureInputBadge()
                }
            }
        }
        .background {
            if let color = pane.adaptiveBackgroundColor {
                Color(cgColor: color)
            }
        }
    }
}

/// Safari-style link preview shown while the mouse hovers an OSC 8 / detected
/// URL in the terminal (`GHOSTTY_ACTION_MOUSE_OVER_LINK`).
private struct LinkHoverBanner: View {
    let url: String

    var body: some View {
        Text(url)
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
            .padding(6)
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
    let focused: Bool
    let isZoomed: Bool
    /// Changes force `updateNSView` after an orphaned-with-no-host event.
    let reattachTick: Int
    let onFocus: () -> Void
    let onProcessExit: () -> Void
    let onCommandFinished: () -> Void
    let onAdaptiveBackgroundChange: (CGColor?) -> Void
    let onSplitRequest: (SplitDirection, SplitPosition) -> Void
    let onZoomRequest: () -> Void

    /// Optional on purpose: the quick terminal's hosting view has no AppState
    /// in its environment, and its ephemeral tab has no rename UI anyway —
    /// the tab-title actions just no-op there.
    @Environment(AppState.self) private var appState: AppState?

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
        let scroll = pane.ensureScrollView()
        attach(scroll, to: host)
        let view = scroll.surfaceView
        configure(view)
        // Defer surface creation until the view is actually in a window — the
        // Metal layer needs a non-zero size to initialize. The re-attach also
        // runs after the whole SwiftUI transaction, so it repairs the
        // teardown-order yank described on `SurfaceHost`.
        DispatchQueue.main.async { [pane] in
            attach(scroll, to: host)
            if view.surface == nil, view.window != nil {
                view.createSurface()
            }
            if focused {
                AdaptiveTerminalChrome.shared.focusDidChange(to: view)
                FocusRestoration.restoreFocus(to: pane.id, finder: { pane }, in: view.window)
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
        scroll.onOrphaned = { [weak pane] in pane?.requestSurfaceReattach() }
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
        let scroll = pane.ensureScrollView()
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
        if focused, !wasFocused {
            AdaptiveTerminalChrome.shared.focusDidChange(to: view)
            view.notifySurfaceFocused()
            FocusRestoration.restoreFocus(to: pane.id, finder: { [pane] in pane }, in: view.window)
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

    private func configure(_ view: GhosttyTerminalNSView) {
        view.onFocus = onFocus
        view.onInteraction = { [weak pane] in
            pane?.recordUserInteraction()
        }
        // Order matters: `onInteraction` clears the tracker's in-place start
        // arming that `onCommandSubmitted` sets, and the view calls them in
        // that order. See `GhosttyTerminalNSView.onCommandSubmitted`.
        view.onCommandSubmitted = { [weak pane] hasContent in
            pane?.recordCommandSubmission(hasContent: hasContent)
        }
        view.canCarryCommandInput = { [weak pane] in pane?.allowsInPlaceOutputStart ?? false }
        // The surface half of the passthrough gate. The key responders decline
        // the event first; without this, `isAppShortcut` would still swallow it
        // here. Both consult `KeybindPassthrough` so they can't disagree.
        view.yieldsToProgram = { [weak pane] event in
            guard let pane else { return false }
            return KeybindPassthrough.yields(event: event, pane: pane)
        }
        view.onProcessExit = onProcessExit
        view.onSplitRequest = onSplitRequest
        view.onZoomRequest = onZoomRequest
        view.isZoomed = isZoomed
        // Each OSC title is a command-boundary signal that re-reads the
        // foreground process, and — when a real program (not the shell) holds
        // the foreground — becomes the pane's display title.
        view.onTitleChange = { [weak pane] title in pane?.receiveReportedTitle(title) }
        view.isFocused = focused

        view.onSearchStart = { [weak pane, weak view] needle in
            guard let pane else { return }
            // Cmd+F toggles: if the search bar is already open, a second
            // start_search closes it (and returns focus to the terminal),
            // mirroring the close button rather than re-opening.
            if pane.searchState.isVisible {
                guard let view else { return }
                view.endSearch()
                // Closing the search bar is a reshape — route focus through
                // FocusRestoration, not a bare makeFirstResponder (see onClose).
                FocusRestoration.restoreFocus(to: pane.id, finder: { [weak pane] in pane }, in: view.window)
                return
            }
            if let needle, !needle.isEmpty { pane.searchState.needle = needle }
            pane.searchState.isVisible = true
            pane.searchState.startPublishing { [weak pane, weak view] q in
                view?.sendSearchQuery(q)
                // The tick scan must run against the needle the core actually
                // searched, not the live (possibly newer) field text.
                pane?.scrollView?.noteSearchNeedle(q)
            }
            if !pane.searchState.needle.isEmpty { pane.searchState.pushNeedle() }
        }
        view.onSearchEnd = { [weak pane] in
            guard let pane else { return }
            pane.searchState.stopPublishing()
            pane.searchState.isVisible = false
            pane.searchState.needle = ""
            pane.searchState.total = nil
            pane.searchState.selected = nil
            pane.scrollView?.clearSearchTicks()
        }
        view.onSearchTotal = { [weak pane] total in
            guard let pane else { return }
            pane.searchState.total = total
            if total == nil {
                pane.scrollView?.clearSearchTicks()
            } else {
                pane.scrollView?.refreshSearchTicks()
            }
        }
        view.onSearchSelected = { [weak pane] sel in
            pane?.searchState.selected = sel
            pane?.scrollView?.setSearchSelected(sel)
        }
        view.onDesktopNotification = { [weak pane, weak view] title, body in
            guard let pane else { return }
            guard !(NSApp.isActive && view?.isFocused == true) else { return }
            Self.postPaneNotification(pane: pane, title: title, body: body)
        }
        view.onProgressStarted = { [weak pane] in
            guard Preferences.shared.showTabStatusIndicator else { return }
            pane?.refreshForegroundProcess()
            pane?.markCommandRunning()
        }
        view.onProgressFinished = { [weak pane] in
            guard let pane,
                  Preferences.shared.showTabStatusIndicator,
                  pane.executionState == .running
            else { return }
            pane.refreshForegroundProcess()
            pane.markProgressFinished()
            onCommandFinished()
        }
        view.onLinkHover = { [weak pane] url in
            pane?.hoverURL = url
        }
        view.onTerminalRender = { [weak view] in
            guard let view else { return }
            AdaptiveTerminalChrome.shared.terminalDidRender(view)
        }
        view.titleProvider = { [weak pane] in pane?.displayTitle }
        view.onPromptTitle = { [weak appState, weak pane] in
            guard let pane else { return }
            appState?.renameTab(containing: pane.id, projectID: pane.projectID)
        }
        view.onSetTabTitle = { [weak appState, weak pane] title in
            guard let pane else { return }
            appState?.setTabTitle(containing: pane.id, projectID: pane.projectID, title: title)
        }
        view.onOutputActivity = { [weak pane, weak view] total in
            if let view {
                AdaptiveTerminalChrome.shared.terminalDidOutput(view)
            }
            guard let pane, Preferences.shared.showTabStatusIndicator else { return }
            // The single activity source. Output heartbeats fire from the pty
            // IO path regardless of occlusion, so they also reach background
            // tabs, and they carry the row total so the tracker can tell
            // growth from an in-place redraw. Always refresh foreground/raw
            // state first: a running canonical command can switch to a raw TUI
            // while normal polling is paused behind a fully occluded window.
            // The heartbeat is throttled to ~2 Hz, and the tracker preserves
            // foreground/progress authority until that raw transition occurs.
            pane.refreshForegroundProcess()
            pane.markOutputActivity(totalRows: total)
        }
        view.onBackgroundColorChange = { [weak view] color in
            guard let view else { return }
            AdaptiveTerminalChrome.shared.terminalBackgroundDidChange(color, in: view)
        }
        view.onAdaptiveBackgroundChange = { color in
            let resolved = color?.usingColorSpace(.sRGB)?.cgColor
            onAdaptiveBackgroundChange(resolved)
        }
        view.onCommandFinished = { [weak pane, weak view] exitCode, durationNs in
            guard let pane else { return }
            // A command boundary is exactly when the pane's identity changes —
            // the program that just exited (claude, hx) is gone and the shell
            // owns the foreground again. Refresh from the process table HERE
            // rather than waiting for the next poll tick: the adaptive poll
            // slows to 2s when the app is inactive and stops entirely once no
            // window is visible, which is why a finished agent's icon and name
            // used to linger until the user clicked or typed. Unconditional —
            // names and agent icons are shown whether or not the status
            // indicator is on, and `notePromptReturned` feeds the naming gate.
            pane.notePromptReturned()
            pane.refreshForegroundProcess()
            // The remote analogue of the refresh above: the local process
            // table only knows the ssh client, so `refreshForegroundProcess`
            // is a no-op for a remote pane — instead request an immediate
            // host probe (bypassing the resolver's throttle) so the finished
            // program's name doesn't linger until the next scheduled probe
            // or user interaction.
            pane.noteRemoteCommandBoundary()
            if Preferences.shared.showTabStatusIndicator {
                pane.markCommandFinished()
                onCommandFinished()
            }
            guard !(NSApp.isActive && view?.isFocused == true) else { return }
            let durationSec = Double(durationNs) / 1_000_000_000
            let body = if exitCode < 0 {
                String(format: "Completed in %@", Self.formatDuration(durationSec))
            } else {
                String(format: "Exited with code %d (%@)", exitCode, Self.formatDuration(durationSec))
            }
            Self.postPaneNotification(pane: pane, title: "Command Finished", body: body)
        }
    }

    /// Post a user notification for a pane, with the single routing-critical
    /// `userInfo` contract (paneID / projectID / isQuickTerminal) defined ONCE
    /// so the desktop-notification and command-finished paths can't drift and
    /// silently break tap-routing for one of them.
    private static func postPaneNotification(pane: Pane, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [
            "paneID": pane.id.uuidString,
            "projectID": pane.projectID.uuidString,
            "isQuickTerminal": pane.projectID == QuickTerminalService.ephemeralProjectID,
        ]
        let request = UNNotificationRequest(
            identifier: "macterm-\(pane.id.uuidString)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private static func formatDuration(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        } else if seconds < 3600 {
            let rounded = Int(seconds.rounded())
            let mins = rounded / 60
            let secs = rounded % 60
            return String(format: "%dm %ds", mins, secs)
        } else {
            let rounded = Int(seconds.rounded())
            let hours = rounded / 3600
            let mins = (rounded % 3600) / 60
            return String(format: "%dh %dm", hours, mins)
        }
    }
}
