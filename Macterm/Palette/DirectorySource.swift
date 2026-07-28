import AppKit
import Foundation

/// Palette source for directory completions. Consulted only when the query
/// looks like a path. If the exact path matches a directory, it's surfaced
/// as the top result — and if that directory is already an opened project,
/// the top item switches to it, with an "add another project" item below
/// (a directory is not an identity; it can back several projects).
@MainActor
struct DirectorySource: PaletteSource {
    func items(query: String, context: PaletteContext) -> [PaletteItem] {
        // A typed remote spec offers add/switch, mirroring local directories
        // (#104). No filesystem browsing — the host isn't consulted; the
        // exact spec is the offer.
        if PaletteQuery.isRemoteSpecQuery(query) {
            return remoteItems(spec: query, context: context)
        }
        let expanded = (query as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return [] }

        let fm = FileManager.default
        let dir: String
        let prefix: String
        let exactMatch: String?

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            dir = expanded
            prefix = ""
            exactMatch = expanded
        } else {
            dir = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent
            exactMatch = nil
        }
        guard fm.fileExists(atPath: dir) else { return [] }

        var items: [PaletteItem] = []

        // Every project-backed directory row pairs switch-first with an
        // "add another project" row directly below — the exact typed path
        // AND child completions alike. A directory is not an identity, so
        // adding a second project must not require typing the full path
        // (a prefix that narrows to one child would otherwise offer only
        // the switch). `score` is a running counter so pairs stay adjacent
        // and ordering stays deterministic.
        var score = 0
        func appendRows(name: String, fullPath: String) {
            let existing = context.projectStore.project(matchingPath: fullPath)
            items.append(directoryItem(
                name: name,
                fullPath: fullPath,
                existing: existing,
                context: context,
                score: score
            ))
            score += 1
            if existing != nil {
                items.append(newProjectItem(name: name, fullPath: fullPath, context: context, score: score))
                score += 1
            }
        }

        // Exact match at the top (when the typed path is itself a directory).
        if let exact = exactMatch {
            appendRows(name: (exact as NSString).lastPathComponent, fullPath: exact)
        }

        // Children rank below every exact-match row.
        let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        entries
            .filter { name in
                let full = (dir as NSString).appendingPathComponent(name)
                var childIsDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &childIsDir), childIsDir.boolValue else { return false }
                // Hide dotdirs — unless the user's typed prefix itself opts into
                // the hidden namespace (e.g. `~/.conf` should complete `.config`).
                if !prefix.hasPrefix("."), name.hasPrefix(".") { return false }
                if prefix.isEmpty { return true }
                return name.lowercased().hasPrefix(prefix.lowercased())
            }
            // `contentsOfDirectory` order is unspecified; sort so BOTH which 10
            // children survive the cap AND their ranking are deterministic
            // across runs and filesystems. The cap counts directories, not
            // rows — a backed child's add-another row rides along.
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .prefix(10)
            .forEach { name in
                appendRows(name: name, fullPath: (dir as NSString).appendingPathComponent(name))
            }

        return items
    }

    func emptyItems(context _: PaletteContext) -> [PaletteItem]? {
        nil
    }

    /// Items for a typed remote spec, shaped like the local exact match: an
    /// existing project matching the spec (structurally, via
    /// `ProjectPath.matches`) switches, with an add-another item below;
    /// otherwise a single item creates the remote project. The display name
    /// is the remote directory's basename, falling back to the host for
    /// `host:~` / `host:/`.
    private func remoteItems(spec: String, context: PaletteContext) -> [PaletteItem] {
        let base = (spec as NSString).lastPathComponent
        let name: String = if base.isEmpty || base == "~" || base == "/" || base == spec {
            ProjectPath.remote(from: spec).flatMap {
                if case let .remote(_, host, _) = $0 { host } else { nil }
            } ?? spec
        } else {
            base
        }
        if let existing = context.projectStore.projects.first(where: { ProjectPath.matches($0.path, spec) }) {
            let switchItem = PaletteItem(
                id: "remote-switch:\(spec)",
                title: existing.name,
                subtitle: "Switch to remote project: \(spec)",
                category: "Directories",
                score: 0
            ) { [appState = context.appState] in
                appState.selectProject(existing)
            }
            return [switchItem, newProjectItem(name: name, fullPath: spec, context: context, score: 1)]
        }
        let addItem = PaletteItem(
            id: "remote-open:\(spec)",
            title: name,
            subtitle: "Add remote project: \(spec)",
            category: "Directories",
            score: 0
        ) { [appState = context.appState, projectStore = context.projectStore] in
            let project = projectStore.findOrCreate(
                name: name,
                path: spec
            )
            appState.selectProject(project)
        }
        return [addItem]
    }

    private func directoryItem(
        name: String,
        fullPath: String,
        existing: Project?,
        context: PaletteContext,
        score: Int
    ) -> PaletteItem {
        if let existing {
            return PaletteItem(
                id: "dir-switch:\(fullPath)",
                title: existing.name,
                subtitle: "Switch to project: \(fullPath)",
                category: "Directories",
                score: score
            ) { [appState = context.appState] in
                appState.selectProject(existing)
            }
        }
        return PaletteItem(
            id: "dir-open:\(fullPath)",
            title: name,
            subtitle: "Open as new project: \(fullPath)",
            category: "Directories",
            score: score
        ) { [appState = context.appState, projectStore = context.projectStore] in
            let project = projectStore.findOrCreate(
                name: name,
                path: fullPath
            )
            appState.selectProject(project)
        }
    }

    /// Offered directly below any switch item whose directory (local or
    /// remote) already backs a project: a directory is not an identity, so a
    /// second, independent project there is a legitimate ask. Always creates
    /// (`ProjectStore.create`), mirroring the folder picker.
    private func newProjectItem(
        name: String,
        fullPath: String,
        context: PaletteContext,
        score: Int
    ) -> PaletteItem {
        PaletteItem(
            id: "dir-new:\(fullPath)",
            title: name,
            subtitle: "Add another project: \(fullPath)",
            category: "Directories",
            score: score
        ) { [appState = context.appState, projectStore = context.projectStore] in
            let project = projectStore.create(
                name: name,
                path: fullPath
            )
            appState.selectProject(project)
        }
    }
}
