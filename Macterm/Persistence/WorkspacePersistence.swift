import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "WorkspacePersistence")

// MARK: - File envelope

/// Current schema version. Bump when the snapshot types change shape.
/// Adding an optional field does NOT require a bump — Codable decodes
/// missing fields as nil / default. Removing or renaming fields does.
private let currentSchemaVersion = 4

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
    /// Whether the pane was left in the "done / needs attention" state when the
    /// app last quit, so the green checkmark survives a restart until the user
    /// acknowledges it. Only `.done` is worth persisting: `.running` can't
    /// outlive the shell process, and `.idle` is the default. Optional so older
    /// snapshots (without the field) decode as nil / idle.
    var needsAttention: Bool?
    /// Stable zmx session id (`Pane.sessionID`). On restore the rebuilt pane
    /// reuses it, so its shell reattaches to the still-running daemon instead
    /// of spawning fresh. Optional: older snapshots decode nil → fresh id.
    var sessionID: UUID?
    /// The pane's zmx session name, persisted VERBATIM — never re-derived. The
    /// name embeds the project slug at creation time, so re-deriving it after
    /// a project rename would target a session that doesn't exist.
    var sessionName: String?
    /// The pane's live working directory at snapshot time, so a session that
    /// did NOT survive (reboot, external kill) respawns where the user was.
    /// A surviving session reattaches with its own live cwd regardless.
    var workingDirectory: String?
    // No `title`: the tab name is derived live from the pane's foreground
    // process, so there's nothing per-pane to persist. (An older snapshot's
    // `title` key is harmlessly ignored on decode.)

    /// Memberwise init with defaults for the optional fields, so call sites
    /// and tests that build old-shape snapshots keep compiling. (SwiftLint
    /// forbids `= nil` on the stored declarations.)
    init(
        id: UUID,
        projectPath: String,
        needsAttention: Bool? = nil,
        sessionID: UUID? = nil,
        sessionName: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.id = id
        self.projectPath = projectPath
        self.needsAttention = needsAttention
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.workingDirectory = workingDirectory
    }
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
    /// Set when `load()` found a present-but-undecodable file. While set,
    /// `save()` refuses to overwrite — a single corrupt field (or a snapshot
    /// written by a newer build) must never let the next autosave clobber the
    /// user's persisted tabs/sessions with empty state.
    private var loadFailed = false

    init(fileURL: URL = FileStorage.fileURL(filename: "workspaces_v3.json")) {
        self.fileURL = fileURL
    }

    func load() -> [WorkspaceSnapshot] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // Could not even read the bytes (transient I/O). Preserve the file:
            // don't let the next save overwrite what we couldn't read.
            logger.error("Failed to read workspaces file: \(error, privacy: .public)")
            loadFailed = true
            return []
        }
        // An empty file is a genuine empty state, not corruption.
        guard !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        // Envelope format first (version + workspaces).
        do {
            let file = try decoder.decode(WorkspacesFile.self, from: data)
            guard file.version <= currentSchemaVersion else {
                // A newer build wrote this. Decoding dropped keys it doesn't
                // know, so re-saving would silently downgrade + lose data.
                // Refuse to persist over it this session.
                logger.error("""
                Workspaces file schema v\(file.version, privacy: .public) is newer than \
                supported v\(currentSchemaVersion, privacy: .public); not overwriting
                """)
                loadFailed = true
                return migrate(file).workspaces
            }
            return migrate(file).workspaces
        } catch let envelopeError {
            // Fallback: pre-envelope format where the file was a bare array of
            // WorkspaceSnapshot. Upgrade on next save.
            if let bare = try? decoder.decode([WorkspaceSnapshot].self, from: data) {
                return clearPersistedAttention(in: bare)
            }
            // Present but decodable as neither shape → corrupt or a format we
            // don't understand. Log the PRIMARY (envelope) error and preserve
            // the file rather than clobbering it with the next save.
            logger.error("Failed to decode workspaces file: \(envelopeError, privacy: .public)")
            loadFailed = true
            return []
        }
    }

    func save(_ snapshots: [WorkspaceSnapshot]) {
        guard !loadFailed else {
            logger.error("Refusing to save workspaces: prior load failed, file preserved")
            return
        }
        do {
            let file = WorkspacesFile(version: currentSchemaVersion, workspaces: snapshots)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save workspaces: \(error, privacy: .public)")
        }
    }

    /// Apply any needed in-memory migrations.
    private func migrate(_ file: WorkspacesFile) -> WorkspacesFile {
        if file.version < 4 {
            // v3 could persist spurious completion checkmarks for tabs that had
            // already been visually cleared. Drop the old attention bits once;
            // v4+ saves them only after the false-start and clear/save fixes.
            logger.info("Migrating workspaces v\(file.version, privacy: .public)→4: clearing persisted attention bits")
            return WorkspacesFile(version: 4, workspaces: clearPersistedAttention(in: file.workspaces))
        }
        return file
    }

    private func clearPersistedAttention(in snapshots: [WorkspaceSnapshot]) -> [WorkspaceSnapshot] {
        snapshots.map { ws in
            WorkspaceSnapshot(
                projectID: ws.projectID,
                activeTabID: ws.activeTabID,
                tabs: ws.tabs.map { tab in
                    TabSnapshot(
                        id: tab.id,
                        customTitle: tab.customTitle,
                        focusedPaneID: tab.focusedPaneID,
                        splitRoot: clearPersistedAttention(in: tab.splitRoot)
                    )
                }
            )
        }
    }

    private func clearPersistedAttention(in node: SplitNodeSnapshot) -> SplitNodeSnapshot {
        switch node {
        case var .pane(p):
            p.needsAttention = nil
            return .pane(p)
        case let .split(b):
            return .split(SplitBranchSnapshot(
                direction: b.direction,
                ratio: b.ratio,
                first: clearPersistedAttention(in: b.first),
                second: clearPersistedAttention(in: b.second)
            ))
        }
    }
}

// MARK: - Snapshot / Restore

@MainActor
enum WorkspaceSerializer {
    static func snapshot(_ workspaces: [UUID: Workspace]) -> [WorkspaceSnapshot] {
        // Sort by projectID so the serialized file is byte-stable across saves
        // (Dictionary.values iteration order is unspecified). restore() is
        // order-independent, so this only tames diff churn on the file.
        workspaces.values.sorted { $0.projectID.uuidString < $1.projectID.uuidString }.map { ws in
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
                let root = restoreNode(t.splitRoot, projectID: snap.projectID)
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
            // `projectPath` is the pane's IDENTITY — persisted verbatim so a
            // remote pane's scp-style spec (`host:dir`) survives restart and
            // still parses as `.remote` (drives ssh + zmx reattach). Never
            // overwrite it with a live cwd.
            //
            // `workingDirectory` is a *local* respawn hint: prefer the shell's
            // live cwd so reopening lands a LOCAL pane back where the user had
            // navigated (OSC 7 `currentPwd` first, then the foreground
            // process's kernel cwd). It is deliberately nil for remote panes —
            // `currentPwd` there is a REMOTE-filesystem path (OSC 7 from the
            // remote shell) that would parse as a bogus local dir on restore
            // and orphan the remote session (the hazard
            // `AppState.replaceProjectPathWithCurrentDir` gates the same way).
            let liveCwd = p.isRemote
                ? nil
                : (p.nsView?.currentPwd ?? ProcessInspector.foregroundWorkingDirectory(forPane: p))
            let needsAttention = p.executionState == .done
            return .pane(PaneSnapshot(
                id: p.id,
                projectPath: p.projectPath,
                needsAttention: needsAttention,
                sessionID: p.sessionID,
                sessionName: p.sessionName,
                workingDirectory: liveCwd
            ))
        case let .split(b):
            return .split(SplitBranchSnapshot(
                direction: b.direction,
                ratio: Double(b.ratio),
                first: snapshotNode(b.first),
                second: snapshotNode(b.second)
            ))
        }
    }

    private static func restoreNode(_ snap: SplitNodeSnapshot, projectID: UUID) -> SplitNode {
        switch snap {
        case let .pane(p):
            // Reuse the persisted session identity so the restored pane
            // reattaches to its still-running zmx daemon: `zmx attach` is an
            // upsert, so a session that died while the app was closed just
            // becomes a fresh shell in the saved working directory — no
            // staleness handling needed. Old snapshots (nil identity) get a
            // fresh session.
            //
            // A LOCAL pane prefers its persisted live cwd (`workingDirectory`)
            // so a respawn lands where the user was; a REMOTE pane persists no
            // `workingDirectory` (see `snapshotNode`), so this falls back to
            // `projectPath` — the scp-style spec that keeps the pane remote.
            let pane = Pane(
                projectPath: p.workingDirectory ?? p.projectPath,
                projectID: projectID,
                sessionID: p.sessionID ?? UUID(),
                sessionName: p.sessionName
            )
            if p.needsAttention == true {
                pane.restoreNeedsAttention()
            }
            return .pane(pane)
        case let .split(b):
            return .split(SplitBranch(
                direction: b.direction,
                ratio: CGFloat(b.ratio),
                first: restoreNode(b.first, projectID: projectID),
                second: restoreNode(b.second, projectID: projectID)
            ))
        }
    }
}
