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

    private var didRestoreExpansion = false
    private(set) var renameTarget: SidebarRenameTarget?
    private(set) var originalCustomTitle: String?

    /// Seed disclosure state once for the shared native/overlay sidebar. The
    /// guard matters because a later overlay appearance must not reopen a
    /// project the user deliberately collapsed after launch.
    func restoreExpansionOnce(
        projectIDs: [UUID],
        activeProjectID: UUID?,
        restoreAllProjects: Bool
    ) {
        guard !didRestoreExpansion else { return }
        didRestoreExpansion = true

        if restoreAllProjects {
            expandedProjects.formUnion(projectIDs)
        } else if let activeProjectID, activeProjectID != PinnedTabs.projectID {
            expandedProjects.insert(activeProjectID)
        }
    }

    func beginRename(
        _ target: SidebarRenameTarget,
        text: String,
        originalCustomTitle: String? = nil
    ) {
        renameTarget = target
        renameText = text
        self.originalCustomTitle = originalCustomTitle
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
    }
}
