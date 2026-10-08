import AppKit
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "CustomPaletteStore")

/// The custom palettes on disk: every `*.yaml`/`*.yml` in
/// `~/.config/macterm/palettes/` (`ProjectFileStore.configDirectoryURL`,
/// which a test's store keeps inside its own directory), each parsed and
/// validated into a `CustomPalette` or kept as the error that stopped it —
/// a broken file is shown where its palette would be, in the palette's
/// Palettes section and in Settings → Palettes, not silently skipped.
///
/// Read-only: the user's editor is the only writer. `reloadIfChanged` is
/// cheap (a directory listing and the files' modification dates), so the
/// palette calls it on every open and the file is never older than that.
@MainActor @Observable
final class CustomPaletteStore {
    struct Entry: Identifiable, Equatable {
        /// The file's stem: what bindings and the Settings switch key on.
        let id: String
        let fileURL: URL
        let result: Result<CustomPalette, CustomPaletteError>
        /// The file's own name, glyph and description as far as its YAML
        /// parses, for a file that failed validation.
        let header: CustomPaletteHeader?

        var palette: CustomPalette? { try? result.get() }
        var failure: CustomPaletteError? {
            if case let .failure(error) = result { return error }
            return nil
        }

        /// The pill a frame of this palette's root shows, and its row's glyph.
        var pill: PalettePill {
            PalettePill(
                title: palette?.name ?? header?.name ?? id,
                systemImage: palette?.icon ?? header?.icon ?? CustomPalette.defaultIcon
            )
        }

        var description: String? { palette?.description ?? header?.description }

        /// The Settings switch's id (`Preferences.disabledPaletteIDs`).
        var settingsID: String { PaletteScopeID.customSettingsID(paletteID: id) }
    }

    let directoryURL: URL
    private(set) var entries: [Entry] = []
    /// What the last load saw, to skip a reload that would find the same.
    private var fingerprint: [String: Date] = [:]

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        reload()
    }

    convenience init(configDirectoryURL: URL) {
        self.init(directoryURL: configDirectoryURL.appendingPathComponent("palettes", isDirectory: true))
    }

    func entry(id: String) -> Entry? {
        entries.first { $0.id == id }
    }

    func palette(id: String) -> CustomPalette? {
        entry(id: id)?.palette
    }

    /// The frame a palette opens on: its root node, nothing exported yet. A
    /// file that didn't read has one too — entering it shows the error.
    func rootTarget(id: String) -> CustomPaletteTarget? {
        guard let entry = entry(id: id) else { return nil }
        return CustomPaletteTarget(paletteID: id, node: entry.palette?.root ?? "root", exports: [:], pill: entry.pill)
    }

    /// Re-read the directory when a file was added, removed or saved since
    /// the last load.
    func reloadIfChanged() {
        if Self.fingerprint(of: directoryURL) != fingerprint { reload() }
    }

    func reload() {
        let files = Self.paletteFiles(in: directoryURL)
        fingerprint = Self.fingerprint(of: directoryURL)
        var seen = Set<String>()
        entries = files.map { url in
            let stem = url.deletingPathExtension().lastPathComponent
            // `git.yaml` and `git.yml` would be one id: bindings, the
            // Settings switch and every lookup key on it. The first by name
            // is the palette; the other says why it isn't.
            guard seen.insert(stem).inserted else {
                let error = CustomPaletteError.invalid("another file is already the palette \(stem); rename one")
                return Entry(id: url.lastPathComponent, fileURL: url, result: .failure(error), header: nil)
            }
            let id = stem
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let header = CustomPaletteFile.parseHeader(yaml: text)
            do {
                let file = try CustomPaletteFile.parse(yaml: text)
                return try Entry(id: id, fileURL: url, result: .success(CustomPalette(file: file, id: id)), header: header)
            } catch let error as CustomPaletteError {
                logger.error("palette \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return Entry(id: id, fileURL: url, result: .failure(error), header: header)
            } catch {
                logger.error("palette \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return Entry(id: id, fileURL: url, result: .failure(.parse(underlying: error)), header: header)
            }
        }
        PaletteHotkeys.shared.paletteIDs = entries.map(\.id)
    }

    /// The directory, created on demand — for Settings' "show in Finder".
    func revealDirectory() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
    }

    private static func paletteFiles(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { ["yaml", "yml"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Each file's modification date — the target's, for a symbolic link
    /// (a dotfiles manager's), whose own date never changes when the file it
    /// points at is saved.
    private static func fingerprint(of directory: URL) -> [String: Date] {
        var dates: [String: Date] = [:]
        for url in paletteFiles(in: directory) {
            dates[url.lastPathComponent] = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        return dates
    }
}
