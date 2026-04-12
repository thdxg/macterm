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
        if let view = views.removeValue(forKey: paneID) {
            view.destroySurface()
        }
    }

    func allViews() -> [GhosttyTerminalNSView] {
        Array(views.values)
    }

    func needsConfirmQuit(for paneID: UUID) -> Bool {
        views[paneID]?.needsConfirmQuit() ?? false
    }
}
