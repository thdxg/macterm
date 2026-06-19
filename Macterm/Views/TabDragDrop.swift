import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Drag-and-drop to move a sidebar tab from one project into another. A tab row
// vends its UUID as the drag payload (`.onDrag`); each project's tab list
// accepts a tab dragged in from a different project through the ForEach
// `.onInsert` hook. We use `.onInsert` rather than `.onDrop` because SwiftUI
// ignores `.onDrop` for views inside a `List` on macOS — `.onInsert` is the
// List-native drop hook, the same family as the `.onMove` that already powers
// within-project tab reordering (`.onMove` only reorders within one ForEach,
// so it can't cross projects). The move runs through `AppState.moveTab`,
// reusing the live `TerminalTab` (and its surfaces/shells) as-is.

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

/// The dragged tab's UUID, read synchronously off the active drag pasteboard
/// during a drop. The drag never leaves the app, so the payload is already on
/// the `.drag` pasteboard — no need to async-load the `.onInsert` item
/// providers (the same shortcut `PaneDropDelegate` takes).
func draggedTabID() -> UUID? {
    guard let data = NSPasteboard(name: .drag).pasteboardItems?
        .compactMap({ $0.data(forType: .mactermTabID) })
        .first, data.count == 16
    else { return nil }
    return data.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
}
