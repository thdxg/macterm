import Foundation

/// The pinned-tabs sentinel: a special workspace that lives outside the
/// project list. Pinned tabs belong to no project — their workspace is keyed
/// by this fixed UUID, which is deliberately NOT a `ProjectStore` row, so
/// everything that iterates real projects (Settings → Projects, the palette's
/// project source, CLI `project list`, sidebar reordering, layout save/apply)
/// never sees it by construction. Only the narrower set of
/// `activeProjectID → Project` lookups needs the synthetic `project` below.
enum PinnedTabs {
    /// Fixed across launches and machines — the workspace snapshot and the
    /// panes' routing identity both key on it. Spelled as raw bytes (not a
    /// force-unwrapped `UUID(uuidString:)`) purely for the linter; this is
    /// `F1E0D0D0-0000-4000-8000-4D6163506E64`.
    static let projectID = UUID(uuid: (
        0xF1, 0xE0, 0xD0, 0xD0, 0x00, 0x00, 0x40, 0x00,
        0x80, 0x00, 0x4D, 0x61, 0x63, 0x50, 0x6E, 0x64
    ))

    static let displayName = "Pinned"

    /// Where a NEW pinned tab (Cmd+T while the pinned workspace is active, a
    /// declared cwd-less leaf) starts: the user's home. Pinned tabs carry no
    /// project directory; each pane's own `projectPath` is its cwd.
    /// `$HOME`-env-first so the benchmark harness's throwaway home isolates it.
    static var fallbackRoot: String { ProjectPath.currentHome }

    /// Synthetic `Project` value for the call sites that render or route by a
    /// `Project` (MainWindow's workspace view, global tab cycling, the CLI's
    /// project resolution). Never inserted into `ProjectStore`.
    static var project: Project {
        Project(id: projectID, name: displayName, path: fallbackRoot)
    }
}

/// One pinned tab's durable identity: a declaration (splits + per-pane
/// cwd/run/shell — the respawn recipe) that outlives the live tab. A record
/// with a matching live `TerminalTab` in the pinned workspace is "loaded";
/// one without is "unloaded" (its sessions died) and is rebuilt from the
/// declaration when selected.
struct PinnedTabRecord: Identifiable, Equatable {
    /// Stable across load/unload cycles; equals the live `TerminalTab.id`
    /// while loaded, and the `id:` written into `pinned.yaml`.
    let id: UUID
    /// The respawn recipe. Captured at pin time, refreshed from live state at
    /// quit, and replaced by hand-edits to `pinned.yaml`. Leaf `cwd`s are
    /// self-contained (absolute / `~` / scp-spec) — there is no project root.
    var declaration: LayoutTab
    /// The project the tab was pinned from — where "Unpin" returns it.
    /// nil for tabs born pinned (Cmd+T in the pinned workspace, a hand-added
    /// file entry); unpin then falls back to the first project.
    var originProjectID: UUID?

    /// Sidebar title for an UNLOADED record (a loaded one shows its live
    /// tab's `displayTitle`): the declared name, else the first declared
    /// command, else the first leaf's cwd, else a generic label.
    var displayTitle: String {
        if let name = declaration.name, !name.isEmpty { return name }
        let panes = Self.leaves(of: declaration.layout)
        if let run = panes.compactMap(\.run).first(where: { !$0.isEmpty }) { return run }
        if let cwd = panes.compactMap(\.cwd).first(where: { !$0.isEmpty }) {
            return (cwd as NSString).lastPathComponent
        }
        return "Pinned Tab"
    }

    private static func leaves(of node: LayoutNode) -> [LayoutPane] {
        switch node {
        case let .pane(p): [p]
        case let .split(b): leaves(of: b.first) + leaves(of: b.second)
        }
    }
}
