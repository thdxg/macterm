import AppKit
import Foundation

/// Palette source for directory completions. Consulted only when the query
/// looks like a path. If the exact path matches a directory, it's surfaced
/// as the top result — and if that directory is already an opened project,
/// the item switches to it instead of creating a duplicate.
@MainActor
struct DirectorySource: PaletteSource {
    func items(query: String, context: PaletteContext) -> [PaletteItem] {
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

        let existingByPath = Dictionary(
            uniqueKeysWithValues: context.projectStore.projects.map { ($0.path, $0) }
        )

        var items: [PaletteItem] = []

        // Exact match at the top (when the typed path is itself a directory).
        if let exact = exactMatch {
            let name = (exact as NSString).lastPathComponent
            items.append(directoryItem(
                name: name,
                fullPath: exact,
                existing: existingByPath[exact],
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
                if name.hasPrefix(".") { return false }
                if prefix.isEmpty { return true }
                return name.lowercased().hasPrefix(prefix.lowercased())
            }
            .prefix(10)
            .enumerated()
            .map { offset, name -> PaletteItem in
                let full = (dir as NSString).appendingPathComponent(name)
                return directoryItem(
                    name: name,
                    fullPath: full,
                    existing: existingByPath[full],
                    context: context,
                    score: offset + 1
                )
            }

        items += children
        return items
    }

    func emptyItems(context _: PaletteContext) -> [PaletteItem]? { nil }

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
            let project = Project(
                name: name,
                path: fullPath,
                sortOrder: projectStore.projects.count
            )
            projectStore.add(project)
            appState.selectProject(project)
        }
    }
}
