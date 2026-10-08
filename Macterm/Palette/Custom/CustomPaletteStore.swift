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
/// Installed extensions (`MactermExtension`) load beside the palette files,
/// from `~/.config/macterm/extensions/<id>/palette.yaml`.
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
        /// An installed extension's folder (`MactermExtension`), which its
        /// commands reach as `MACTERM_EXTENSION_DIR`; nil for a palette file.
        var extensionDirectory: URL?
        /// Who maintains it, from its `extension.yaml`.
        var authors: [String] = []

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
    }

    let directoryURL: URL
    /// Installed extensions (`MactermExtension`), one folder each, beside
    /// the palettes folder: `~/.config/macterm/extensions/`.
    let extensionsURL: URL
    private(set) var entries: [Entry] = []
    /// What the last load saw, to skip a reload that would find the same.
    private var fingerprint: [String: Date] = [:]

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
        extensionsURL = directoryURL.deletingLastPathComponent().appendingPathComponent("extensions", isDirectory: true)
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

    /// Re-read the folders when a file was added, removed or saved since
    /// the last load.
    func reloadIfChanged() {
        if currentFingerprint() != fingerprint { reload() }
    }

    func reload() {
        let files = Self.paletteFiles(in: directoryURL)
        fingerprint = currentFingerprint()
        var seen = Set<String>()
        let palettes = files.map { url in
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
        // Installed extensions after the palette files, in one namespace: an
        // extension whose id a palette file already has says so rather than
        // shadowing it, as two files of one name do.
        let extensions = Self.extensionFolders(in: extensionsURL).map { folder in
            let id = folder.lastPathComponent
            guard seen.insert(id).inserted else {
                let error = CustomPaletteError.invalid("a palette file is already the palette \(id); rename or remove one")
                return Entry(id: "extensions/\(id)", fileURL: folder, result: .failure(error), header: nil)
            }
            return Self.extensionEntry(id: id, folder: folder)
        }
        entries = palettes + extensions
        PaletteHotkeys.shared.paletteIDs = entries.map(\.id)
    }

    /// An installed extension's palette, with who maintains it.
    private static func extensionEntry(id: String, folder: URL) -> Entry {
        let paletteURL = folder.appendingPathComponent(MactermExtension.paletteName)
        let text = (try? String(contentsOf: paletteURL, encoding: .utf8)) ?? ""
        let header = CustomPaletteFile.parseHeader(yaml: text)
        let manifestText = (try? String(contentsOf: folder.appendingPathComponent(MactermExtension.manifestName), encoding: .utf8)) ?? ""
        let manifest = try? ExtensionManifest.parse(yaml: manifestText)
        let result: Result<CustomPalette, CustomPaletteError>
        do {
            result = try .success(CustomPalette(file: CustomPaletteFile.parse(yaml: text), id: id))
        } catch let error as CustomPaletteError {
            logger.error("extension \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            result = .failure(error)
        } catch {
            result = .failure(.parse(underlying: error))
        }
        var entry = Entry(id: id, fileURL: paletteURL, result: result, header: header)
        entry.extensionDirectory = folder
        entry.authors = manifest?.authors ?? []
        return entry
    }

    /// The directory, created on demand — for Settings' "show in Finder".
    /// Moves an installed palette to the Trash — an extension's whole
    /// folder, or a palette file — and reloads, so it leaves the palette at
    /// once. The Trash is the undo.
    func uninstall(id: String) throws {
        guard let entry = entry(id: id) else { return }
        try FileManager.default.trashItem(at: entry.extensionDirectory ?? entry.fileURL, resultingItemURL: nil)
        reload()
    }

    func revealExtensionsDirectory() {
        try? FileManager.default.createDirectory(at: extensionsURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([extensionsURL])
    }

    func revealDirectory() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
    }

    /// The installed extensions: folders holding a `palette.yaml`.
    private static func extensionFolders(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(MactermExtension.paletteName).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
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

    /// Each palette file's and installed extension palette's modification
    /// date — the target's, for a symbolic link (a dotfiles manager's), whose
    /// own date never changes when the file it points at is saved.
    private func currentFingerprint() -> [String: Date] {
        var dates: [String: Date] = [:]
        func record(_ url: URL, as key: String) {
            dates[key] = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
        }
        for url in Self.paletteFiles(in: directoryURL) {
            record(url, as: url.lastPathComponent)
        }
        for folder in Self.extensionFolders(in: extensionsURL) {
            record(folder.appendingPathComponent(MactermExtension.paletteName), as: "extensions/\(folder.lastPathComponent)")
        }
        return dates
    }
}
