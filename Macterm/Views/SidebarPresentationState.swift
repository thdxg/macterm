import AppKit
import Foundation
import Observation

enum SidebarItem: Hashable {
    case project(UUID)
    case tab(projectID: UUID, tabID: UUID)
}

enum SidebarRenameTarget: Equatable {
    case project(UUID)
    case tab(UUID)
}

/// Transient UI state shared by every presentation of `SidebarContent`.
///
/// The native split-view sidebar remains mounted while the hover overlay shows
/// a second copy of the same content. Keeping this state on either view would
/// give the copies different expansion/selection state and two competing
/// rename fields. `MainWindow` tells each copy whether it is interactive; this
/// shared state makes them one logical sidebar without lifecycle arbitration.
@MainActor @Observable
final class SidebarPresentationState {
    var expandedProjects: Set<UUID> = []
    var selection: Set<SidebarItem> = []
    var scrollPosition: SidebarItem?
    var renameText = ""

    /// Every row the sidebar is currently showing, in visual order (pinned
    /// records, then each project's header followed by its tabs while it is
    /// expanded). `SidebarContent` publishes it because it is the view that
    /// builds that order; it exists so a shift-click can resolve the range
    /// between two rows. Empty until the first publish.
    var orderedItems: [SidebarItem] = []

    /// The row a shift-click extends *from* — the last row that ended up as
    /// the whole selection, however it got there (a native click on a row's
    /// icon or padding, a title click, or `syncSelection` following a tab
    /// switch). AppKit keeps the same anchor for the List's own rows, so
    /// tracking single-selection is what keeps the two in step.
    var selectionAnchor: SidebarItem?

    private(set) var renameTarget: SidebarRenameTarget?
    private(set) var originalCustomTitle: String?

    func beginRename(
        _ target: SidebarRenameTarget,
        text: String,
        originalCustomTitle: String? = nil
    ) {
        renameTarget = target
        renameText = text
        self.originalCustomTitle = originalCustomTitle
        // A rename opened by double-clicking an inactive row also switches to
        // it, and the pane that becomes focused asks for first responder on a
        // retry loop that can outlive this gesture. See the flag's own notes.
        FocusRestoration.isEditingInlineName = true
    }

    /// Apply a click on `item` to the selection, standing in for the List's
    /// own handling of the clicks it never sees — a press landing on a row's
    /// title is owned by that title's gesture (see `InlineRenameClickTarget`).
    ///
    /// Shift extends the range from `selectionAnchor` rather than adding the
    /// one row: the selection drives the bulk "Close N Tabs" / "Remove N
    /// Projects" actions, so inserting alone means clicking row 1 and
    /// shift-clicking row 5 acts on 2 rows instead of 5. With no usable anchor
    /// — nothing selected yet, or its row since closed — shift selects just
    /// the clicked row, as AppKit does.
    func selectRow(_ item: SidebarItem, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if selection.contains(item) {
                selection.remove(item)
            } else {
                selection.insert(item)
            }
        } else if modifiers.contains(.shift),
                  let anchor = selectionAnchor,
                  anchor != item,
                  let range = itemRange(from: anchor, to: item)
        {
            selection = Set(range)
        } else {
            selection = [item]
        }
    }

    /// The inclusive run of visible rows between two items, in visual order —
    /// the selection a shift-click produces. Nil when either row has since
    /// gone (a closed tab, a collapsed project), so the caller can fall back
    /// to selecting the clicked row alone.
    func itemRange(from anchor: SidebarItem, to item: SidebarItem) -> [SidebarItem]? {
        guard let start = orderedItems.firstIndex(of: anchor),
              let end = orderedItems.firstIndex(of: item)
        else { return nil }
        return Array(orderedItems[min(start, end) ... max(start, end)])
    }

    func isRenaming(_ target: SidebarRenameTarget) -> Bool {
        renameTarget == target
    }

    func completeRename(_ target: SidebarRenameTarget) -> (text: String, originalCustomTitle: String?)? {
        guard isRenaming(target) else { return nil }
        let result = (renameText, originalCustomTitle)
        clearRename()
        return result
    }

    func cancelRename(_ target: SidebarRenameTarget) -> Bool {
        guard isRenaming(target) else { return false }
        clearRename()
        return true
    }

    /// Drop any draft when a temporary overlay closes without being promoted.
    /// Promotion deliberately skips this so the native presentation can carry
    /// the same editor forward.
    func discardRename() {
        clearRename()
    }

    private func clearRename() {
        renameTarget = nil
        renameText = ""
        originalCustomTitle = nil
        FocusRestoration.isEditingInlineName = false
    }
}
