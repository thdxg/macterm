import AppKit
import Foundation

/// Palette source for directory completions. Consulted only when the query
/// looks like a path. If the exact path matches a directory, it's surfaced
/// as the top result — and if that directory is already an opened project,
/// the item switches to it instead of creating a duplicate.
@MainActor
struct DirectorySource: PaletteSource {
    func items(query: String, context: PaletteContext) -> [PaletteItem] {
        // A typed remote spec offers add/switch, mirroring local directories
        // (#104). No filesystem browsing — the host isn't consulted; the
        // exact spec is the offer.
        if PaletteQuery.isRemoteSpecQuery(query) {
            return [remoteItem(spec: query, context: context)]
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

        // Exact match at the top (when the typed path is itself a directory).
        if let exact = exactMatch {
            let name = (exact as NSString).lastPathComponent
            items.append(directoryItem(
                name: name,
                fullPath: exact,
                existing: context.projectStore.project(matchingPath: exact),
                context: context,
                score: 0
            ))
        }

        let entries = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        let children = entries
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
            // across runs and filesystems.
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .prefix(10)
            .enumerated()
            .map { offset, name -> PaletteItem in
                let full = (dir as NSString).appendingPathComponent(name)
                return directoryItem(
                    name: name,
                    fullPath: full,
                    existing: context.projectStore.project(matchingPath: full),
                    context: context,
                    score: offset + 1
                )
            }

        items += children
        return items
    }

    func emptyItems(context _: PaletteContext) -> [PaletteItem]? {
        nil
    }

    /// Add-or-switch for a typed remote spec, shaped like `directoryItem`:
    /// an existing project matching the spec (structurally, via
    /// `ProjectPath.matches`) switches; otherwise the item creates the
    /// remote project. The display name is the remote directory's basename,
    /// falling back to the host for `host:~` / `host:/`.
    private func remoteItem(spec: String, context: PaletteContext) -> PaletteItem {
        if let existing = context.projectStore.projects.first(where: { ProjectPath.matches($0.path, spec) }) {
            return PaletteItem(
                id: "remote-switch:\(spec)",
                title: existing.name,
                subtitle: "Switch to remote project: \(spec)",
                category: "Directories",
                score: 0
            ) { [appState = context.appState] in
                appState.selectProject(existing)
            }
        }
        let base = (spec as NSString).lastPathComponent
        let name: String = if base.isEmpty || base == "~" || base == "/" || base == spec {
            ProjectPath.remote(from: spec).flatMap {
                if case let .remote(_, host, _) = $0 { host } else { nil }
            } ?? spec
        } else {
            base
        }
        return PaletteItem(
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
}
