import AppKit
import SwiftUI

/// Folders dragged onto the sidebar — from Finder or anything else that writes
/// file URLs — each become a new project, exactly as Open With or the Finder
/// service would make them (`AppState.openProjects`).
///
/// It is an AppKit view laid over the whole sidebar, not a `.dropDestination`:
/// the List's outline view claims every drag over the sidebar, so a SwiftUI
/// destination on the List never fires (see the notes in `SidebarContent`),
/// and one on the rows would kill their insertion lines. AppKit picks a drag's
/// destination as the topmost view registered for a type on the pasteboard,
/// without consulting `hitTest`, so this view can be transparent to every
/// click and scroll while still taking file drags. It registers for file URLs
/// only, and no in-app drag (tab, project, pane) carries one, so those still
/// reach the outline beneath. A drag with no folder in it is refused here
/// rather than passed on — nothing in the sidebar took files before either.
/// The only feedback is the cursor's "+": the project lands at the end of the
/// list, not at a slot, so there is no insertion line to draw.
///
/// The terminal's own drop (a path pasted at the cursor) is
/// `GhosttyTerminalNSView`'s and is untouched: this view covers the sidebar
/// alone.
struct SidebarFolderDropTarget: NSViewRepresentable {
    let isEnabled: Bool
    let onDrop: ([String]) -> Void

    func makeNSView(context _: Context) -> DropView {
        let view = DropView()
        configure(view)
        return view
    }

    func updateNSView(_ view: DropView, context _: Context) {
        configure(view)
    }

    private func configure(_ view: DropView) {
        view.isEnabled = isEnabled
        view.onDrop = onDrop
    }

    final class DropView: NSView {
        var onDrop: (([String]) -> Void)?
        var isEnabled = false {
            didSet {
                guard isEnabled != oldValue else { return }
                if isEnabled {
                    registerForDraggedTypes([.fileURL])
                } else {
                    unregisterDraggedTypes()
                }
            }
        }

        /// The folders the drag in progress names, read once on entry — each
        /// is a file-system lookup, and `draggingUpdated` fires per mouse move.
        private var directories: [String] = []

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            directories = Self.directories(on: sender.draggingPasteboard)
            return operation()
        }

        override func draggingUpdated(_: any NSDraggingInfo) -> NSDragOperation {
            operation()
        }

        override func draggingEnded(_: any NSDraggingInfo) {
            directories = []
        }

        override func performDragOperation(_: any NSDraggingInfo) -> Bool {
            let paths = directories
            guard !paths.isEmpty else { return false }
            // Deferred, as the terminal's drop is, so the drag session has
            // unwound before the sidebar reshapes under it.
            DispatchQueue.main.async { [weak self] in self?.onDrop?(paths) }
            return true
        }

        /// .copy gives the drop the green "+" cursor, as on the terminal.
        private func operation() -> NSDragOperation {
            directories.isEmpty ? [] : .copy
        }

        static func directories(on pasteboard: NSPasteboard) -> [String] {
            let urls = pasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            return DocumentOpenRequest.resolve(urls).directories
        }
    }
}
