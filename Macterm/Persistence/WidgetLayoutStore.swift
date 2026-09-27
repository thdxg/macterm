import Foundation
import os
import Yams

private let logger = Logger(subsystem: appBundleID, category: "WidgetLayoutStore")

// The auto-maintained declaration of the desktop widgets:
// `~/.config/macterm/widgets.yaml`, beside `pinned.yaml`. The widgets' counterpart of
// `pinned.yaml` (`PinnedLayoutStore`), with the same two writers — the app,
// on every change and at quit, and the user's editor — and the same rule
// that makes that safe: the store tracks the exact text of its own last
// write, and callers absorb an external change before overwriting it
// (`AppState.writeWidgetLayout`). Its own schema, since a widget has a size
// and a place where a pinned tab has splits:
//
//     widgets:
//       - name: logs              # optional — display and matching only
//         size: medium            # small | medium | large | extra-large | CxR
//         column: 3               # the grid cell of its top-left corner,
//         row: 1                  #   counted from the screen's top-left
//         display: DELL U2723QE   # optional — the screen, by name; absent
//                                 #   means the primary display
//         cwd: ~/dev/api          # optional — where a fresh shell starts
//         run: tail -f dev.log    # optional — typed into a fresh shell
//
// Position is in grid cells, not points: widgets always sit on the grid
// (`DesktopWidgetGrid`), and a cell survives a resolution change where a
// point doesn't. `cwd` and `run` are the respawn recipe — used when the
// widget has no session to reattach (a reboot, or an entry added by hand) —
// captured from the live pane the way a pinned tab's are.

/// One entry of `widgets.yaml`.
struct WidgetDeclaration: Codable, Equatable {
    var name: String?
    /// A family name or a `CxR` span (`DesktopWidgetSize.parseSpan`). nil or
    /// unparseable → Settings → Widgets' default size.
    var size: String?
    var column: Int?
    var row: Int?
    var display: String?
    var cwd: String?
    var run: String?
}

/// The file itself.
struct WidgetLayoutFile: Codable, Equatable {
    var widgets: [WidgetDeclaration]?

    static let schemaModeline =
        "# yaml-language-server: $schema=https://raw.githubusercontent.com/thdxg/macterm/main/assets/widgets.schema.json"

    static func parse(yaml: String) throws -> WidgetLayoutFile {
        do {
            return try YAMLDecoder().decode(WidgetLayoutFile.self, from: yaml)
        } catch {
            throw LayoutFileError.parse(underlying: error)
        }
    }

    func yaml() throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = false
        return try "\(Self.schemaModeline)\n\(encoder.encode(self))"
    }
}

/// Pairs `widgets.yaml` entries with the live widgets WITHOUT a wire-level
/// id — ids are hostile to the hand-editing the file exists for. The rules
/// are `PinnedLayoutMatcher`'s: by `name:` first, then by an exactly equal
/// entry (an untouched entry finds its widget even after a reorder), then by
/// position among the leftovers where the names don't contradict — so a
/// remove-plus-add is never mistaken for an edit that keeps the old shell.
enum WidgetLayoutMatcher {
    struct Matching {
        /// One element per file entry, in file order; `widget` is the index
        /// into the widgets the entry matched, nil for an addition.
        var pairs: [(entry: WidgetDeclaration, widget: Int?)]
        /// Widgets no entry claimed — removals.
        var removed: [Int]
    }

    static func match(entries: [WidgetDeclaration], current: [WidgetDeclaration]) -> Matching {
        var consumed = Set<Int>()
        var byEntry: [Int?] = Array(repeating: nil, count: entries.count)
        for (i, entry) in entries.enumerated() {
            guard let name = entry.name, !name.isEmpty else { continue }
            if let index = current.indices.first(where: { !consumed.contains($0) && current[$0].name == name }) {
                byEntry[i] = index
                consumed.insert(index)
            }
        }
        for (i, entry) in entries.enumerated() where byEntry[i] == nil {
            if let index = current.indices.first(where: { !consumed.contains($0) && current[$0] == entry }) {
                byEntry[i] = index
                consumed.insert(index)
            }
        }
        for (i, entry) in entries.enumerated() where byEntry[i] == nil {
            if let index = current.indices.first(where: {
                !consumed.contains($0) && namesCompatible(entry.name, current[$0].name)
            }) {
                byEntry[i] = index
                consumed.insert(index)
            }
        }
        return Matching(
            pairs: Array(zip(entries, byEntry)),
            removed: current.indices.filter { !consumed.contains($0) }
        )
    }

    private static func namesCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        (lhs?.isEmpty == false ? lhs : nil) == (rhs?.isEmpty == false ? rhs : nil)
    }
}

@MainActor
struct WidgetLayoutStore {
    static let filename = "widgets.yaml"

    /// `~/.config/macterm` — user config, shared across debug and release
    /// like `projects/` beside it (only the sessions are per flavor).
    /// `ProjectFileStore.configDirectoryURL`, so tests isolate it
    /// automatically.
    let directoryURL: URL

    var fileURL: URL { directoryURL.appendingPathComponent(Self.filename) }

    enum ReadResult {
        /// No file, or an empty one — NOT "no widgets": absence is "no
        /// external input", so an editor's truncate-then-write save can't
        /// remove every widget.
        case absent
        case file(widgets: [WidgetDeclaration], text: String)
        /// Present but unparseable. Callers suspend auto-writes so a mid-edit
        /// typo isn't clobbered.
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
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .absent }
        do {
            return try .file(widgets: WidgetLayoutFile.parse(yaml: text).widgets ?? [], text: text)
        } catch {
            return .invalid("\(Self.filename) is not valid: \(error.localizedDescription)")
        }
    }

    /// Serialize and write the file. Returns the exact text written, the
    /// caller's external-edit baseline.
    @discardableResult
    func write(widgets: [WidgetDeclaration]) throws -> String {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let header = """
        # Managed by Macterm — the desktop widgets. Safe to hand-edit: Macterm
        # reads your changes at launch and before each of its own writes. An
        # added entry becomes a widget; removing an entry removes its widget
        # at the next launch. Macterm rewrites this file whenever a widget is
        # added, moved, resized or removed, and on quit.
        """
        let body = try WidgetLayoutFile(widgets: widgets).yaml()
        let text = "\(header)\n\(body)"
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        logger.info("Wrote \(Self.filename, privacy: .public) with \(widgets.count, privacy: .public) widgets")
        return text
    }
}
