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
                        // Return focus to the terminal so typing resumes
                        // without requiring a click.
                        view.window?.makeFirstResponder(view)
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            TerminalSurface(
                pane: pane,
                focused: focused,
                isZoomed: isZoomed,
                onFocus: onFocus,
                onProcessExit: onProcessExit,
                onCommandFinished: onCommandFinished,
                onSplitRequest: onSplitRequest,
                onZoomRequest: onZoomRequest
            )
        }
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
    let onFocus: () -> Void
    let onProcessExit: () -> Void
    let onCommandFinished: () -> Void
    let onSplitRequest: (SplitDirection, SplitPosition) -> Void
    let onZoomRequest: () -> Void

    final class Coordinator {
        var wasFocused = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SurfaceScrollView {
        // SwiftUI hosts the scroll view; the surface lives inside it. Both are
        // owned by `Pane` so they survive tab switches / split reshapes.
        let scroll = pane.ensureScrollView()
        // The pane may have been warmed off-screen by `SurfaceIncubator` (its
        // shell already running). Detach it from the incubator window before
        // SwiftUI inserts it — a view can't live in two superviews. This does
        // not tear down the surface (only `pane.destroySurface()` does).
        scroll.removeFromSuperview()
        let view = scroll.surfaceView
        configure(view)
        // Defer surface creation until the view is actually in a window — the
        // Metal layer needs a non-zero size to initialize.
        DispatchQueue.main.async { [pane] in
            if view.surface == nil, view.window != nil {
                view.createSurface()
            }
            if focused {
                FocusRestoration.restoreFocus(to: pane.id, finder: { pane }, in: view.window)
            }
        }
        context.coordinator.wasFocused = focused
        return scroll
    }

    func updateNSView(_ scroll: SurfaceScrollView, context: Context) {
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
            view.notifySurfaceFocused()
            FocusRestoration.restoreFocus(to: pane.id, finder: { [pane] in pane }, in: view.window)
        } else if !focused, wasFocused {
            view.notifySurfaceUnfocused()
        }
    }

    static func dismantleNSView(_ scroll: SurfaceScrollView, coordinator _: Coordinator) {
        // Intentionally empty. The scroll view and its surface are owned by
        // `Pane`; SwiftUI just borrows them. When the pane is removed from the
        // tree, AppState calls pane.destroySurface() explicitly.
        // SwiftUI will have already removed the view from its superview by
        // the time this runs, so we don't need to do anything here.
        _ = scroll
    }

    private func configure(_ view: GhosttyTerminalNSView) {
        view.onFocus = onFocus
        view.onInteraction = { [weak pane] in
            pane?.recordUserInteraction()
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
                view.window?.makeFirstResponder(view)
                return
            }
            if let needle, !needle.isEmpty { pane.searchState.needle = needle }
            pane.searchState.isVisible = true
            pane.searchState.startPublishing { [weak view] q in view?.sendSearchQuery(q) }
            if !pane.searchState.needle.isEmpty { pane.searchState.pushNeedle() }
        }
        view.onSearchEnd = { [weak pane] in
            guard let pane else { return }
            pane.searchState.stopPublishing()
            pane.searchState.isVisible = false
            pane.searchState.needle = ""
            pane.searchState.total = nil
            pane.searchState.selected = nil
        }
        view.onSearchTotal = { [weak pane] total in pane?.searchState.total = total }
        view.onSearchSelected = { [weak pane] sel in pane?.searchState.selected = sel }
        view.onDesktopNotification = { [weak pane, weak view] title, body in
            guard let pane else { return }
            guard !(NSApp.isActive && view?.isFocused == true) else { return }
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
        view.onTerminalActivity = { [weak pane] in
            guard let pane, Preferences.shared.showTabStatusIndicator else { return }
            pane.refreshForegroundProcess()
            pane.markTerminalActivity()
        }
        view.onTerminalRender = { [weak pane] in
            guard let pane, Preferences.shared.showTabStatusIndicator else { return }
            // Renders also happen for prompt redraws and input echo. Use them to
            // keep an already-detected command active (including in-place
            // spinners), but don't let a render alone start the status spinner.
            if pane.executionState != .running {
                pane.refreshForegroundProcess()
            }
            if pane.executionState == .running {
                pane.markTerminalActivity()
            }
        }
        view.onCommandFinished = { [weak pane, weak view] exitCode, durationNs in
            guard let pane else { return }
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
            let content = UNMutableNotificationContent()
            content.title = "Command Finished"
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
