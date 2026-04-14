import AppKit
import SwiftUI

struct TerminalPane: View {
    let pane: Pane
    let focused: Bool
    let viewCache: TerminalViewCache
    let onFocus: () -> Void
    let onProcessExit: () -> Void
    let onSplitRequest: (SplitDirection, SplitPosition) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TerminalAnchor(
                pane: pane,
                focused: focused,
                viewCache: viewCache,
                onFocus: onFocus,
                onProcessExit: onProcessExit,
                onSplitRequest: onSplitRequest
            )

            if pane.searchState.isVisible {
                TerminalSearchBar(
                    searchState: pane.searchState,
                    onNavigateNext: { viewCache.existingView(for: pane.id)?.navigateSearch(direction: .next) },
                    onNavigatePrevious: { viewCache.existingView(for: pane.id)?.navigateSearch(direction: .previous) },
                    onClose: { viewCache.existingView(for: pane.id)?.endSearch() }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }
}

/// An NSViewRepresentable that creates an invisible placeholder.
/// The real terminal view lives in the portal overlay and is positioned to match this anchor.
private struct TerminalAnchor: NSViewRepresentable {
    let pane: Pane
    let focused: Bool
    let viewCache: TerminalViewCache
    let onFocus: () -> Void
    let onProcessExit: () -> Void
    let onSplitRequest: (SplitDirection, SplitPosition) -> Void

    final class Coordinator {
        var wasFocused = false
        var paneID: UUID?
        var portalHost: TerminalPortalHost?
        var terminalView: GhosttyTerminalNSView?
        var frameObserver: NSObjectProtocol?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView(frame: .zero)
        // Invisible placeholder — the real terminal is in the portal
        anchor.wantsLayer = false
        context.coordinator.wasFocused = focused

        DispatchQueue.main.async {
            guard let window = anchor.window else { return }
            let host = TerminalPortal.host(for: window)
            host.install()

            let termView = viewCache.view(for: pane.id, workingDirectory: pane.projectPath)
            configure(termView)

            context.coordinator.paneID = pane.id
            context.coordinator.portalHost = host
            context.coordinator.terminalView = termView

            host.bind(paneID: pane.id, terminalView: termView, anchor: anchor, visible: true)

            // Create surface if needed (the terminal view is now in the window via portal)
            if termView.surface == nil {
                termView.createSurface()
            }

            if focused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    termView.window?.makeFirstResponder(termView)
                }
            }

            // Observe frame changes to reposition the terminal view
            let paneID = pane.id
            context.coordinator.frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak host] _ in
                MainActor.assumeIsolated {
                    guard let host else { return }
                    host.layoutEntry(paneID)
                }
            }
        }

        return anchor
    }

    func updateNSView(_ anchor: NSView, context: Context) {
        guard let termView = context.coordinator.terminalView,
              let host = context.coordinator.portalHost
        else { return }

        configure(termView)

        let wasFocused = context.coordinator.wasFocused
        context.coordinator.wasFocused = focused
        termView.isFocused = focused
        if focused, !wasFocused {
            termView.notifySurfaceFocused()
            DispatchQueue.main.async { termView.window?.makeFirstResponder(termView) }
        } else if !focused {
            termView.notifySurfaceUnfocused()
        }

        // Update anchor reference and layout
        host.bind(paneID: pane.id, terminalView: termView, anchor: anchor, visible: true)
    }

    static func dismantleNSView(_ anchor: NSView, coordinator: Coordinator) {
        // Do NOT remove the terminal from the portal here.
        // SwiftUI transiently dismantles views during tab switches.
        // The terminal view stays in the portal until explicitly unbound (pane close).
        if let observer = coordinator.frameObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // Hide the terminal view since its anchor is gone
        if let paneID = coordinator.paneID, let host = coordinator.portalHost {
            host.setVisible(false, for: paneID)
        }
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
