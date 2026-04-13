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
            TerminalBridge(
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

private struct TerminalBridge: NSViewRepresentable {
    let pane: Pane
    let focused: Bool
    let viewCache: TerminalViewCache
    let onFocus: () -> Void
    let onProcessExit: () -> Void
    let onSplitRequest: (SplitDirection, SplitPosition) -> Void

    final class Coordinator { var wasFocused = false }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> GhosttyTerminalNSView {
        let view = viewCache.view(for: pane.id, workingDirectory: pane.projectPath)
        configure(view)
        context.coordinator.wasFocused = focused
        if focused {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { view.window?.makeFirstResponder(view) }
        }
        return view
    }

    func updateNSView(_ view: GhosttyTerminalNSView, context: Context) {
        configure(view)
        let wasFocused = context.coordinator.wasFocused
        context.coordinator.wasFocused = focused
        view.isFocused = focused
        if focused, !wasFocused {
            view.notifySurfaceFocused()
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        } else if !focused {
            view.notifySurfaceUnfocused()
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
