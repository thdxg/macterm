import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "PinnedLayoutStore")

// The auto-maintained declaration of the pinned tabs:
// `~/.config/macterm/projects/pinned.yaml`. Unlike every other file in that
// directory it has TWO writers — the app (on pin/unpin/membership change and
// at quit) and the user's editor — so the store tracks the exact text of its
// own last write and callers absorb any external change before overwriting
// (see `AppState.writePinnedLayout`). It IS a `ProjectFile` — same schema as
// every other layout file, editor validation included — whose `path:` is
// the reserved literal `pinned` (see `PinnedTabs.pathMarker`):
//
//     path: <pinned>          # the marker that makes this file the pinned set
//     tabs:
//       - name: dev server
//         run: npm run dev
//         cwd: ~/dev/api
//
// Leaf `cwd`s are self-contained (absolute / `~` / scp-spec) — there is no
// project root — which also means one pinned set can mix local and remote
// panes, something project layouts (one root) can't express.
//
// The marker keeps the file out of the project-file machinery by
// construction: `ProjectPath.parse("<pinned>")` is nil (not absolute, `~`,
// or scp-style — and `<` is illegal in a hostname, so not even a mistyped
// remote spec can look like it), so `ProjectPath.matches` pairs it with no
// project — plus
// `listAll` filters the reserved filename and `write` never binds or
// realign-deletes it.

/// Pairs `pinned.yaml` entries with the existing records WITHOUT a wire-level
/// id — a UUID on every entry was hostile to exactly the hand-editing the
/// file exists for (and churned dotfile diffs). Matching mirrors
/// `LayoutReconciler.matchTab`: by `name:` first, then by exact layout
/// content (an unchanged entry matches its record even after a reorder),
/// then positionally among the leftovers. The consequences of a mismatch are
/// deliberately non-destructive — a live pinned tab is at worst unpinned
/// (moved to its origin project), never killed — so fuzzy matching is safe;
/// giving entries a `name:` makes hand-edits unambiguous.
enum PinnedLayoutMatcher {
    struct Matching {
        /// One element per file entry, in file order; `record` is the
        /// existing record the entry matched (its declaration should adopt
        /// the entry), nil for a genuine addition.
        var pairs: [(entry: LayoutTab, record: PinnedTabRecord?)]
        /// Records no file entry claimed — removals.
        var removed: [PinnedTabRecord]
    }

    static func match(entries: [LayoutTab], records: [PinnedTabRecord]) -> Matching {
        var consumed = Set<UUID>()
        var byEntry: [PinnedTabRecord?] = Array(repeating: nil, count: entries.count)
        // Pass 1: name.
        for (i, entry) in entries.enumerated() {
            guard let name = entry.name, !name.isEmpty else { continue }
            if let record = records.first(where: { !consumed.contains($0.id) && $0.declaration.name == name }) {
                byEntry[i] = record
                consumed.insert(record.id)
            }
        }
        // Pass 2: exact layout content.
        for (i, entry) in entries.enumerated() where byEntry[i] == nil {
            if let record = records.first(where: { !consumed.contains($0.id) && $0.declaration.layout == entry.layout }) {
                byEntry[i] = record
                consumed.insert(record.id)
            }
        }
        // Pass 3: positional among the leftovers (the edited-in-place case)
        // — but only where the names don't CONTRADICT (equal, or both
        // absent). Without that constraint, a remove+add pair would silently
        // convert into an "edit", keeping a live session the user meant to
        // unpin under the new entry's declaration.
        var leftovers = records.filter { !consumed.contains($0.id) }
        for (i, entry) in entries.enumerated() where byEntry[i] == nil {
            guard let index = leftovers.firstIndex(where: { namesCompatible(entry.name, $0.declaration.name) })
            else { continue }
            let record = leftovers.remove(at: index)
            byEntry[i] = record
            consumed.insert(record.id)
        }
        return Matching(
            pairs: Array(zip(entries, byEntry)),
            removed: records.filter { !consumed.contains($0.id) }
        )
    }

    private static func namesCompatible(_ a: String?, _ b: String?) -> Bool {
        let a = a?.isEmpty == false ? a : nil
        let b = b?.isEmpty == false ? b : nil
        return a == b
    }
}

extension LayoutNode {
    /// Merge a freshly captured pinned declaration with the previous one so
    /// an established `run:` is never ERASED by a capture that observed the
    /// pane idle. The live capture reads what's running NOW, which is nil at
    /// a shell prompt — but for a pinned tab the `run:` is the respawn recipe,
    /// and moments where the pane reads idle include exactly the ones that
    /// must not lose it: the eager launch before a spawned command has
    /// started, a crashed process back at the prompt, a capture racing the
    /// zmx resolver. A leaf therefore inherits the previous declaration's
    /// `run` when the new capture has none at the same tree position; a NEW
    /// observed command still replaces the old one, and a reshaped tree takes
    /// the fresh capture as-is.
    func preservingRuns(from previous: LayoutNode) -> LayoutNode {
        switch (self, previous) {
        case let (.pane(fresh), .pane(old)):
            guard fresh.run == nil, let oldRun = old.run else { return self }
            var merged = fresh
            merged.run = oldRun
            // `run` and `shell` are mutually exclusive on a leaf: keeping the
            // old command means dropping the idle capture's shell.
            merged.shell = nil
            return .pane(merged)
        case let (.split(fresh), .split(old)) where fresh.direction == old.direction:
            return .split(LayoutBranch(
                direction: fresh.direction,
                ratio: fresh.ratio,
                first: fresh.first.preservingRuns(from: old.first),
                second: fresh.second.preservingRuns(from: old.second)
            ))
        default:
            return self
        }
    }
}

@MainActor
struct PinnedLayoutStore {
    static let filename = "pinned.yaml"

    /// Lives in the projects directory (user config, shared across
    /// debug/release like the ghostty config — the pinned SET is user-level;
    /// only the live sessions are per-flavor). Derived from the injected
    /// `ProjectFileStore` directory so tests isolate it automatically.
    let directoryURL: URL

    var fileURL: URL { directoryURL.appendingPathComponent(Self.filename) }

    enum ReadResult {
        /// No file — NOT "no pinned tabs": an absent file is treated as "no
        /// external input" (never as "remove everything"), so an editor's
        /// delete-then-rewrite save can't spuriously unpin the whole set.
        case absent
        /// Parsed and carries the `path: <pinned>` marker.
        case file(tabs: [LayoutTab], text: String)
        /// Present but unparseable, or missing the marker (a foreign file —
        /// e.g. a hand-crafted project file squatting on the name). Callers
        /// suspend auto-writes so a mid-edit typo can't get clobbered.
        case invalid(String)
    }

    func read() -> ReadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .absent }
        let text: String
        do {
            text = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            return .invalid("could not read \(Self.filename): \(error.localizedDescription)")
        }
        // An empty file is a transient editor state (truncate-then-write), not
        // a request to unpin everything.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .absent }
        let file: ProjectFile
        do {
            file = try ProjectFile.parse(yaml: text)
        } catch {
            return .invalid("\(Self.filename) is not valid YAML: \(error.localizedDescription)")
        }
        guard file.path.trimmingCharacters(in: .whitespaces).lowercased() == PinnedTabs.pathMarker else {
            return .invalid("\(Self.filename) is missing the `path: \(PinnedTabs.pathMarker)` marker; not touching it")
        }
        return .file(tabs: file.tabs ?? [], text: text)
    }

    /// Serialize and write the canonical file. Returns the exact text written
    /// so the caller can record it as the external-edit baseline.
    @discardableResult
    func write(tabs: [LayoutTab]) throws -> String {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let header = """
        # Managed by Macterm — the pinned tabs' layout. Safe to hand-edit:
        # an entry added here appears as a pinned tab on the next launch, and
        # removing an entry unpins its tab (honored at launch). Macterm
        # rewrites this file when tabs are pinned or unpinned and on quit.
        """
        // A real ProjectFile whose reserved `path:` marks it as the pinned
        // set — one schema for every layout file, modeline included.
        let body = try ProjectFile(name: nil, path: PinnedTabs.pathMarker, zmxPath: nil, tabs: tabs).yaml()
        let text = "\(header)\n\(body)"
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        logger.info("Wrote \(Self.filename, privacy: .public) with \(tabs.count, privacy: .public) tabs")
        return text
    }
}
