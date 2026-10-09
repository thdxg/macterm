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
/// Installed extensions (`MactermExtension`) load beside them, from
/// `~/.config/macterm/extensions/<id>/`: each is listed in `extensions`, and
/// each of its palettes (`palettes/*.yaml`) is an entry like a file's, under
/// the id `<extension>/<stem>`.
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
        /// The installed extension it belongs to, and that extension's
        /// folder, which its commands reach as `MACTERM_EXTENSION_DIR`; nil
        /// for a palette file of the user's own.
        var extensionID: String?
        var extensionDirectory: URL?

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

    /// An installed extension (`MactermExtension`): its folder, its
    /// `extension.yaml` as read, and the ids of its palettes in `entries`.
    struct InstalledExtension: Identifiable, Equatable {
        let id: String
        let folder: URL
        let manifest: Result<ExtensionManifest, CustomPaletteError>
        let paletteIDs: [String]
        /// What's wrong with it, if anything: its manifest, the first of its
        /// palettes that doesn't read, or no palette at all.
        let problem: String?

        var name: String { (try? manifest.get())?.name ?? id }
        var description: String? { try? manifest.get().description }
        var icon: String { (try? manifest.get())?.icon ?? MactermExtension.defaultIcon }
        var authors: [String] { (try? manifest.get())?.authors ?? [] }
    }

    let directoryURL: URL
    /// Installed extensions (`MactermExtension`), one folder each, beside
    /// the palettes folder: `~/.config/macterm/extensions/`.
    let extensionsURL: URL
    private(set) var entries: [Entry] = []
    private(set) var extensions: [InstalledExtension] = []
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
            // every lookup key on it. The first by name
            // is the palette; the other says why it isn't.
            guard seen.insert(stem).inserted else {
                let error = CustomPaletteError.invalid("another file is already the palette \(stem); rename one")
                return Entry(id: url.lastPathComponent, fileURL: url, result: .failure(error), header: nil)
            }
            return Self.entry(id: stem, url: url)
        }
        // Installed extensions after the palette files. Their palettes'
        // ids carry the extension's (`<extension>/<stem>`), so they never meet
        // a file's or another extension's.
        var extensionEntries: [Entry] = []
        extensions = Self.extensionFolders(in: extensionsURL).map { folder in
            let id = folder.lastPathComponent
            let palettes = Self.extensionEntries(id: id, folder: folder)
            extensionEntries += palettes
            let manifest = Self.manifest(in: folder)
            let problem: String? = if case let .failure(error) = manifest {
                error.localizedDescription
            } else if let broken = palettes.first(where: { $0.failure != nil }), let failure = broken.failure {
                "\(MactermExtension.palettesFolder)/\(broken.fileURL.lastPathComponent): \(failure.localizedDescription)"
            } else if palettes.isEmpty {
                "no palettes in \(MactermExtension.palettesFolder)/"
            } else {
                nil
            }
            return InstalledExtension(id: id, folder: folder, manifest: manifest, paletteIDs: palettes.map(\.id), problem: problem)
        }
        entries = palettes + extensionEntries
        PaletteHotkeys.shared.paletteIDs = entries.map(\.id)
    }

    /// A palette file read and validated, or kept with the error that
    /// stopped it.
    private static func entry(id: String, url: URL) -> Entry {
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

    /// An installed extension's `extension.yaml`, or why it didn't read.
    private static func manifest(in folder: URL) -> Result<ExtensionManifest, CustomPaletteError> {
        let text = (try? String(contentsOf: folder.appendingPathComponent(MactermExtension.manifestName), encoding: .utf8)) ?? ""
        do {
            return try .success(ExtensionManifest.parse(yaml: text))
        } catch let error as CustomPaletteError {
            return .failure(error)
        } catch {
            return .failure(.parse(underlying: error))
        }
    }

    /// An installed extension's palettes, each read like a palette file.
    private static func extensionEntries(id extensionID: String, folder: URL) -> [Entry] {
        let palettesFolder = folder.appendingPathComponent(MactermExtension.palettesFolder, isDirectory: true)
        var seen = Set<String>()
        return paletteFiles(in: palettesFolder).compactMap { url in
            let id = MactermExtension.paletteID(extensionID: extensionID, path: url.lastPathComponent)
            guard seen.insert(id).inserted else { return nil }
            var entry = entry(id: id, url: url)
            entry.extensionID = extensionID
            entry.extensionDirectory = folder
            return entry
        }
    }

    func installedExtension(id: String) -> InstalledExtension? {
        extensions.first { $0.id == id }
    }

    /// Moves an installed extension's folder to the Trash and reloads, so
    /// its palettes leave the command palette at once. The Trash is the undo.
    func uninstall(extensionID id: String) throws {
        guard let installed = installedExtension(id: id) else { return }
        try FileManager.default.trashItem(at: installed.folder, resultingItemURL: nil)
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

    /// The installed extensions: folders holding an `extension.yaml`.
    private static func extensionFolders(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent(MactermExtension.manifestName).path) }
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
            let id = folder.lastPathComponent
            record(folder.appendingPathComponent(MactermExtension.manifestName), as: "extensions/\(id)")
            let palettes = folder.appendingPathComponent(MactermExtension.palettesFolder, isDirectory: true)
            for url in Self.paletteFiles(in: palettes) {
                record(url, as: "extensions/\(id)/\(url.lastPathComponent)")
            }
        }
        return dates
    }
}
