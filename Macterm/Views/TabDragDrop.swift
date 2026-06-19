import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Drag-and-drop to move a sidebar tab from one project into another. A tab row
// is a drag source carrying its UUID; every project row is a drop target.
// Dropping a tab onto a project hands off to `AppState.moveTab`, which reuses
// the `TerminalTab` (and its live surfaces/shells) as-is — only the owning
// workspace changes. This is the direct-manipulation counterpart of the
// "Move to Project" context-menu command for the same operation.

extension UTType {
    /// In-app drag payload identifying the tab being moved: its UUID bytes.
    static let mactermTabID = UTType(exportedAs: "com.thdxg.macterm.tab-id")
}

extension NSPasteboard.PasteboardType {
    static let mactermTabID = NSPasteboard.PasteboardType(UTType.mactermTabID.identifier)
}

/// The drag payload for a sidebar tab row: the tab's UUID bytes, scoped to this
/// process (the drag never leaves the app).
@MainActor
func tabDragItemProvider(for tabID: UUID) -> NSItemProvider {
    let provider = NSItemProvider()
    let data = withUnsafeBytes(of: tabID.uuid) { Data($0) }
    provider.registerDataRepresentation(
        forTypeIdentifier: UTType.mactermTabID.identifier,
        visibility: .ownProcess
    ) { completion in
        completion(data, nil)
        return nil
    }
    return provider
}

/// Drop target for a sidebar project row: accepts a dragged tab and moves it
/// into this project. `isTargeted` drives the row's drop highlight.
struct TabDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    /// Performs the move; receives the dragged tab's UUID.
    let onDropTab: @MainActor (UUID) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.mactermTabID])
    }

    func dropEntered(info _: DropInfo) {
        isTargeted = true
    }

    func dropExited(info _: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        isTargeted = false
        // The drag never leaves the app (the payload is .ownProcess), so the
        // tab ID can be read synchronously off the drag pasteboard instead of
        // round-tripping through the item provider — same as PaneDropDelegate.
        guard let data = NSPasteboard(name: .drag).pasteboardItems?
            .compactMap({ $0.data(forType: .mactermTabID) })
            .first, data.count == 16
        else { return false }
        let tabID = data.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        MainActor.assumeIsolated { onDropTab(tabID) }
        return true
    }
}
