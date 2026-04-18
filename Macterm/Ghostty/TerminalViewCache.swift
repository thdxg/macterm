import AppKit
import Foundation

/// Caches GhosttyTerminalNSView instances by pane ID so they survive SwiftUI re-renders.
@MainActor
final class TerminalViewCache {
    static let shared = TerminalViewCache()

    private var views: [UUID: GhosttyTerminalNSView] = [:]

    func view(for paneID: UUID, workingDirectory: String) -> GhosttyTerminalNSView {
        if let existing = views[paneID] { return existing }
        let view = GhosttyTerminalNSView(workingDirectory: workingDirectory)
        views[paneID] = view
        return view
    }

    func existingView(for paneID: UUID) -> GhosttyTerminalNSView? {
        views[paneID]
    }

    func remove(for paneID: UUID) {
        guard let view = views.removeValue(forKey: paneID) else { return }
        // Clear callbacks first so any in-flight ghostty actions (including those
        // fired from destroySurface) can't re-enter and trigger another close.
        view.onProcessExit = nil
        view.onTitleChange = nil
        view.onSearchStart = nil
        view.onSearchEnd = nil
        view.onSearchTotal = nil
        view.onSearchSelected = nil
        // Unbind from the portal first (which hides + removes the view).
        if let window = view.window ?? view.superview?.window {
            TerminalPortal.host(for: window).unbind(paneID: paneID)
        }
        view.destroySurface()
    }

    func allViews() -> [GhosttyTerminalNSView] {
        Array(views.values)
    }

    func needsConfirmQuit(for paneID: UUID) -> Bool {
        views[paneID]?.needsConfirmQuit() ?? false
    }

    func anyNeedsConfirmQuit() -> Bool {
        views.values.contains { $0.needsConfirmQuit() }
    }
}
