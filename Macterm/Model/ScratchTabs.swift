import Foundation

/// The scratch-tabs sentinel (#665): a workspace for tabs that belong to no
/// project, and that are not pinned. It is the second workspace that lives
/// outside the project list, after `PinnedTabs`. Like that one, its key is a
/// fixed UUID that is deliberately NOT a `ProjectStore` row, so every path
/// that iterates real projects never sees it.
///
/// A scratch tab is an ordinary `TerminalTab` in an ordinary `Workspace`. The
/// difference from a project tab is only what is around it: no project
/// directory (a new tab starts in home), no layout file, no rename, no color,
/// no worktrees, and no unload. The difference from a pinned tab is the
/// lifecycle: closing a scratch tab closes it for good, and nothing declares it
/// in a YAML file. The snapshot in `workspaces_v3.json` is its only record,
/// as for a project tab.
enum ScratchTabs {
    /// Fixed across launches and machines. Spelled as raw bytes for the
    /// linter, like `PinnedTabs.projectID`; this is
    /// `F1E0D0D0-0000-4000-8000-4D6163536372`.
    static let projectID = UUID(uuid: (
        0xF1, 0xE0, 0xD0, 0xD0, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x4D, 0x61, 0x63, 0x53, 0x63, 0x72
    ))

    /// The sidebar header and the window title. Not localized, like
    /// `PinnedTabs.displayName`: it is also the name the CLI resolves.
    static let displayName = "Scratch Tabs"

    /// The short selector the CLI also accepts: `--project scratch`.
    static let shortName = "scratch"

    /// The header's icon. The project headers draw the user's project icon;
    /// this one is fixed, so the section never reads as one more project.
    static let iconSymbol = "tray"

    /// Whether `name` is this workspace's, which no project may carry.
    /// `ControlHandler.resolveProject` reads both spellings as the scratch
    /// workspace before it looks at any project. Case-insensitive and blind
    /// to padding, as `PinnedTabs.reservesName`.
    static func reservesName(_ name: String) -> Bool {
        let folded = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return folded == displayName.lowercased() || folded == shortName
    }

    /// Why a typed name was refused, as the app says it.
    static let reservedNameMessage = String(
        localized: "“\(displayName)” is a reserved name for the tabs without a project. Select another name."
    )

    /// Where a new scratch tab starts: the user's home, as a pinned tab does.
    /// `tab-inherit-working-directory` still applies, so a tab opened from a
    /// scratch pane can follow that pane's directory.
    static var fallbackRoot: String { ProjectPath.currentHome }

    /// Synthetic `Project` value for the call sites that render or route by a
    /// `Project`. Never inserted into `ProjectStore`.
    static var project: Project {
        Project(id: projectID, name: displayName, path: fallbackRoot)
    }
}
