import Foundation
import os

private let logger = Logger(subsystem: "com.thdxg.macterm", category: "WorkspacePersistence")

// MARK: - File envelope

/// Current schema version. Bump when the snapshot types change shape.
/// Adding an optional field does NOT require a bump — Codable decodes
/// missing fields as nil / default. Removing or renaming fields does.
private let currentSchemaVersion = 3

/// Top-level on-disk representation. Wraps the workspace array so we can
/// evolve the file format (add fields, do migrations) without renaming the
/// file. Readers that encounter the old bare-array format still work.
struct WorkspacesFile: Codable {
    var version: Int
    var workspaces: [WorkspaceSnapshot]
}

// MARK: - Snapshot types

struct WorkspaceSnapshot: Codable {
    let projectID: UUID
    let activeTabID: UUID?
    let tabs: [TabSnapshot]
}

struct TabSnapshot: Codable {
    let id: UUID
    let customTitle: String?
    let focusedPaneID: UUID?
    let splitRoot: SplitNodeSnapshot
}

indirect enum SplitNodeSnapshot: Codable {
    case pane(PaneSnapshot)
    case split(SplitBranchSnapshot)

    private enum CodingKeys: String, CodingKey { case type, pane, split }
    private enum NodeType: String, Codable { case pane, split }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(NodeType.self, forKey: .type) {
        case .pane: self = try .pane(c.decode(PaneSnapshot.self, forKey: .pane))
        case .split: self = try .split(c.decode(SplitBranchSnapshot.self, forKey: .split))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .pane(p):
            try c.encode(NodeType.pane, forKey: .type)
            try c.encode(p, forKey: .pane)
        case let .split(b):
            try c.encode(NodeType.split, forKey: .type)
            try c.encode(b, forKey: .split)
        }
    }
}

struct PaneSnapshot: Codable {
    let id: UUID
    let projectPath: String
    let title: String
}

struct SplitBranchSnapshot: Codable {
    let direction: SplitDirection
    let ratio: Double
    let first: SplitNodeSnapshot
    let second: SplitNodeSnapshot
}

// MARK: - Persistence

final class WorkspaceStore {
    private let fileURL: URL

    init(fileURL: URL = FileStorage.fileURL(filename: "workspaces_v3.json")) {
        self.fileURL = fileURL
    }

    func load() -> [WorkspaceSnapshot] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            // Try the envelope format first (version + workspaces).
            if let file = try? decoder.decode(WorkspacesFile.self, from: data) {
                return migrate(file).workspaces
            }
            // Fallback: pre-envelope format where the file was a bare array
            // of WorkspaceSnapshot. Upgrade on next save.
            return try decoder.decode([WorkspaceSnapshot].self, from: data)
        } catch {
            logger.error("Failed to load workspaces: \(error)")
            return []
        }
    }

    func save(_ snapshots: [WorkspaceSnapshot]) {
        do {
            let file = WorkspacesFile(version: currentSchemaVersion, workspaces: snapshots)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            try encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save workspaces: \(error)")
        }
    }

    /// Apply any needed in-memory migrations. Currently a no-op — future
    /// schema bumps add cases here.
    private func migrate(_ file: WorkspacesFile) -> WorkspacesFile {
        // switch file.version {
        // case 3: return file
        // case 4: return migrateV4(file)
        // ...
        // }
        file
    }
}

// MARK: - Snapshot / Restore

@MainActor
enum WorkspaceSerializer {
    static func snapshot(_ workspaces: [UUID: Workspace]) -> [WorkspaceSnapshot] {
        workspaces.values.map { ws in
            WorkspaceSnapshot(
                projectID: ws.projectID,
                activeTabID: ws.activeTabID,
                tabs: ws.tabs.map { tab in
                    TabSnapshot(
                        id: tab.id,
                        customTitle: tab.customTitle,
                        focusedPaneID: tab.focusedPaneID,
                        splitRoot: snapshotNode(tab.splitRoot)
                    )
                }
            )
        }
    }

    static func restore(from snapshots: [WorkspaceSnapshot], validIDs: Set<UUID>) -> [Workspace] {
        snapshots.compactMap { snap in
            guard validIDs.contains(snap.projectID) else { return nil }
            let tabs = snap.tabs.map { t in
                let root = restoreNode(t.splitRoot)
                let focused = t.focusedPaneID.flatMap { root.findPane(id: $0)?.id } ?? root.allPanes().first?.id
                return TerminalTab(id: t.id, splitRoot: root, focusedPaneID: focused, customTitle: t.customTitle)
            }
            guard !tabs.isEmpty else { return nil }
            return Workspace(projectID: snap.projectID, tabs: tabs, activeTabID: snap.activeTabID)
        }
    }

    static func snapshotNode(_ node: SplitNode) -> SplitNodeSnapshot {
        switch node {
        case let .pane(p):
            // Prefer the shell's live cwd over the pane's original project
            // path so reopening the app lands each pane back in the directory
            // the user had navigated to. Falls back to projectPath when the
            // surface hasn't reported a pwd yet.
            let path = p.nsView?.currentPwd ?? p.projectPath
            return .pane(PaneSnapshot(id: p.id, projectPath: path, title: p.title))
        case let .split(b):
            return .split(SplitBranchSnapshot(
                direction: b.direction,
                ratio: Double(b.ratio),
                first: snapshotNode(b.first),
                second: snapshotNode(b.second)
            ))
        }
    }

    private static func restoreNode(_ snap: SplitNodeSnapshot) -> SplitNode {
        switch snap {
        case let .pane(p):
            let pane = Pane(projectPath: p.projectPath)
            pane.title = p.title
            return .pane(pane)
        case let .split(b):
            return .split(SplitBranch(
                direction: b.direction,
                ratio: CGFloat(b.ratio),
                first: restoreNode(b.first),
                second: restoreNode(b.second)
            ))
        }
    }
}
