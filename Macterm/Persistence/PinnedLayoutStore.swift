import Foundation
import os
import Yams

private let logger = Logger(subsystem: appBundleID, category: "PinnedLayoutStore")

/// The auto-maintained declaration of the pinned tabs:
/// `~/.config/macterm/projects/pinned.yaml`. Unlike every other file in that
/// directory it has TWO writers — the app (on pin/unpin/membership change and
/// at quit) and the user's editor — so the store tracks the exact text of its
/// own last write and callers absorb any external change before overwriting
/// (see `AppState.writePinnedLayoutIfNeeded`). The file's schema:
///
///     pinned: true            # the marker that makes this file ours
///     tabs:                   # LayoutTab schema + a per-tab `id:`
///       - id: 6D0B…           # app-assigned; omit when hand-adding
///         name: dev server
///         run: npm run dev
///         cwd: ~/dev/api
///
/// Leaf `cwd`s are self-contained (absolute / `~` / scp-spec) — there is no
/// project root — which also means one pinned set can mix local and remote
/// panes, something project layouts (one root) can't express.
///
/// The `pinned: true` marker (and the absence of `path:`) is what keeps the
/// file out of the project-file machinery: `ProjectFileStore.matches` skips it
/// (no declared path), `listAll` filters the reserved filename, and `write`
/// never binds or realign-deletes it.
struct PinnedLayoutFile: Codable, Equatable {
    var pinned: Bool?
    var tabs: [LayoutTab]?
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
        /// Parsed and carries the `pinned: true` marker.
        case file(PinnedLayoutFile, text: String)
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
        let file: PinnedLayoutFile
        do {
            file = try YAMLDecoder().decode(PinnedLayoutFile.self, from: text)
        } catch {
            return .invalid("\(Self.filename) is not valid YAML: \(error.localizedDescription)")
        }
        guard file.pinned == true else {
            return .invalid("\(Self.filename) is missing the `pinned: true` marker; not touching it")
        }
        return .file(file, text: text)
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
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = false
        let body = try encoder.encode(PinnedLayoutFile(pinned: true, tabs: tabs))
        let text = "\(header)\n\(body)"
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        logger.info("Wrote \(Self.filename, privacy: .public) with \(tabs.count, privacy: .public) tabs")
        return text
    }
}
