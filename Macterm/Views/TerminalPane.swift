import AppKit
import SwiftUI

struct TerminalPane: View {
    let pane: Pane
    let focused: Bool
    let onFocus: () -> Void
    let onProcessExit: () -> Void
    let onSplitRequest: (SplitDirection, SplitPosition) -> Void

    var body: some View {
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
                onFocus: onFocus,
                onProcessExit: onProcessExit,
                onSplitRequest: onSplitRequest
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
    let onFocus: () -> Void
    let onProcessExit: () -> Void
    let onSplitRequest: (SplitDirection, SplitPosition) -> Void

    final class Coordinator {
        var wasFocused = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> GhosttyTerminalNSView {
        let view = pane.ensureNSView()
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
        return view
    }

    func updateNSView(_ view: GhosttyTerminalNSView, context: Context) {
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

    static func dismantleNSView(_ view: GhosttyTerminalNSView, coordinator _: Coordinator) {
        // Intentionally empty. The NSView is owned by `Pane`; SwiftUI just
        // borrows it. When the pane is removed from the tree, AppState calls
        // pane.destroySurface() explicitly.
        // SwiftUI will have already removed the view from its superview by
        // the time this runs, so we don't need to do anything here.
        _ = view
    }

    private func configure(_ view: GhosttyTerminalNSView) {
        view.onFocus = onFocus
        view.onProcessExit = onProcessExit
        view.onSplitRequest = onSplitRequest
        view.onTitleChange = { [weak pane] title in pane?.title = title }
        view.isFocused = focused

        view.onSearchStart = { [weak pane] needle in
            guard let pane else { return }
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
    }
}
