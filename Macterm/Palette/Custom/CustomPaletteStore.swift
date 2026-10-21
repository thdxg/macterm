import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "CustomPaletteStore")

/// The installed extensions (`MactermExtension`) on disk, one folder each in
/// `~/.config/macterm/extensions/` (in `ProjectFileStore.configDirectoryURL`,
/// which a test's store keeps inside its own directory). Each extension is
/// in `extensions`. Each of its palettes (`palettes/*.yaml`) is an entry,
/// with the id `<extension>/<stem>`. Macterm parses and validates each
/// palette into a `CustomPalette`, or keeps the error that stopped it. A
/// broken file shows where its palette would be, in the Palettes section of
/// the command palette and on the card of its extension in Settings →
/// Extensions. Macterm does not skip it silently.
///
/// Macterm reads palettes only from extensions. A palette file in
/// `~/.config/macterm/palettes/`, which earlier versions read, is not read.
///
/// Read-only: the user's editor is the only writer. `reloadIfChanged` is
/// cheap (a directory listing and the files' modification dates), so the
/// palette calls it on every open and the file is never older than that.
@MainActor @Observable
final class CustomPaletteStore {
    struct Entry: Identifiable, Equatable {
        /// `<extension>/<file stem>`: the key of bindings and of every lookup.
        let id: String
        let fileURL: URL
        let result: Result<CustomPalette, CustomPaletteError>
        /// The file's own name and description as far as its YAML parses,
        /// for a file that failed validation.
        let header: CustomPaletteHeader?
        /// The installed extension that it belongs to, and the folder of that
        /// extension. Its commands get the folder as `MACTERM_EXTENSION_DIR`.
        var extensionID: String?
        var extensionDirectory: URL?
        /// The icon of its extension (`MactermExtension.icon(of:file:)`).
        /// Every palette of an extension shows it, so the palettes and the
        /// card of the extension have one glyph. The `icon:` of a palette
        /// file is not used.
        var extensionIcon: PaletteIcon = .symbol(MactermExtension.defaultIcon)

        var palette: CustomPalette? { try? result.get() }
        var failure: CustomPaletteError? {
            if case let .failure(error) = result { return error }
            return nil
        }

        /// The pill a frame of this palette's root shows, and its row's glyph.
        var pill: PalettePill {
            PalettePill(
                title: palette?.name ?? header?.name ?? id,
                icon: extensionIcon
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
        /// What its card and each of its palettes show.
        let icon: PaletteIcon
        /// Where it came from, when Install put it here. nil for an
        /// extension of the user's own.
        let source: ExtensionSource?
        /// Its files on disk, by path, as Git blob SHAs (`ExtensionSource.files(in:)`).
        let files: [String: String]
        /// What's wrong with it, if anything: its manifest, the first of its
        /// palettes that doesn't read, no palette at all, or its icon file.
        let problem: String?
        /// What the extension adds to Macterm, one name for each feature, for
        /// example "Kubernetes palette". Today the features are its palettes.
        /// A later capability adds its own names here, so that each message
        /// about the extension (`uninstallMessage`) names all of them.
        let features: [String]

        /// What the uninstall prompt says: the features that go with the
        /// extension (`deletionMessage`).
        var uninstallMessage: String {
            Self.deletionMessage(features.isEmpty ? [name] : features)
        }

        /// "A will be deleted.", "A and B will be deleted.", and for more
        /// than two, "A, B, and 3 more features will be deleted."
        static func deletionMessage(_ names: [String]) -> String {
            switch names.count {
            case 0,
                 1: String(localized: "\(names.first ?? "") will be deleted.")
            case 2: String(localized: "\(names[0]) and \(names[1]) will be deleted.")
            case 3: String(localized: "\(names[0]), \(names[1]), and 1 more feature will be deleted.")
            default: String(localized: "\(names[0]), \(names[1]), and \(names.count - 2) more features will be deleted.")
            }
        }

        var name: String { (try? manifest.get())?.name ?? id }
        var description: String? { try? manifest.get().description }
        /// Whether the user changed it since Install wrote it. An extension
        /// with no source record has nothing to differ from.
        var isModified: Bool { source.map { $0.files != files } ?? false }
        var authors: [String] { (try? manifest.get())?.authors ?? [] }
    }

    /// The folder of installed extensions, `~/.config/macterm/extensions/`.
    let extensionsURL: URL
    private(set) var entries: [Entry] = []
    private(set) var extensions: [InstalledExtension] = []
    /// What the last load saw, to skip a reload that would find the same.
    private var fingerprint: [String: Date] = [:]
    /// The icon files that the manifests named at the last load, so that an
    /// edit to one is seen as an edit to a palette is.
    private var iconFiles: [URL] = []

    init(extensionsURL: URL) {
        self.extensionsURL = extensionsURL
        reload()
    }

    convenience init(configDirectoryURL: URL) {
        self.init(extensionsURL: configDirectoryURL.appendingPathComponent("extensions", isDirectory: true))
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
        fingerprint = currentFingerprint()
        // The id of a palette includes the id of its extension
        // (`<extension>/<stem>`), so two extensions never share a palette id.
        var extensionEntries: [Entry] = []
        var iconFiles: [URL] = []
        extensions = Self.extensionFolders(in: extensionsURL).map { folder in
            let id = folder.lastPathComponent
            let manifest = Self.manifest(in: folder)
            let (icon, iconProblem) = MactermExtension.icon(of: try? manifest.get()) { path in
                let url = folder.appendingPathComponent(path)
                iconFiles.append(url)
                return try? Data(contentsOf: url)
            }
            let palettes = Self.extensionEntries(id: id, folder: folder, icon: icon)
            extensionEntries += palettes
            let problem: String? = if case let .failure(error) = manifest {
                error.localizedDescription
            } else if let broken = palettes.first(where: { $0.failure != nil }), let failure = broken.failure {
                "\(MactermExtension.palettesFolder)/\(broken.fileURL.lastPathComponent): \(failure.localizedDescription)"
            } else if palettes.isEmpty {
                "no palettes in \(MactermExtension.palettesFolder)/"
            } else {
                iconProblem.map { "\(MactermExtension.manifestName): \($0)" }
            }
            return InstalledExtension(
                id: id,
                folder: folder,
                manifest: manifest,
                paletteIDs: palettes.map(\.id),
                icon: icon,
                source: ExtensionSource.read(in: folder),
                files: ExtensionSource.files(in: folder),
                problem: problem,
                features: palettes.map { palette in
                    String(
                        localized: "\(palette.pill.title) palette",
                        comment: "A feature of an extension, named in the prompt to uninstall it"
                    )
                }
            )
        }
        entries = extensionEntries
        // The fingerprint above was taken before the manifests named their
        // icon files. Add their dates now.
        self.iconFiles = iconFiles
        for url in iconFiles {
            fingerprint[Self.iconKey(url)] = Self.modificationDate(url)
        }
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
            logger.error("palette \(id, privacy: .public): \(EnglishErrorText.describe(error), privacy: .public)")
            return Entry(id: id, fileURL: url, result: .failure(error), header: header)
        } catch {
            logger.error("palette \(id, privacy: .public): \(EnglishErrorText.describe(error), privacy: .public)")
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

    /// An installed extension's palettes, each read like a palette file,
    /// each with the icon of the extension.
    private static func extensionEntries(id extensionID: String, folder: URL, icon: PaletteIcon) -> [Entry] {
        let palettesFolder = folder.appendingPathComponent(MactermExtension.palettesFolder, isDirectory: true)
        var seen = Set<String>()
        return paletteFiles(in: palettesFolder).map { url in
            let id = MactermExtension.paletteID(extensionID: extensionID, path: url.lastPathComponent)
            // `git.yaml` and `git.yml` would have one id. The first by name is
            // the palette. The other one says why it is not.
            var entry: Entry
            if seen.insert(id).inserted {
                entry = Self.entry(id: id, url: url)
            } else {
                let stem = url.deletingPathExtension().lastPathComponent
                let error = CustomPaletteError.invalid("another file is already the palette \(stem). Rename one")
                entry = Entry(id: "\(extensionID)/\(url.lastPathComponent)", fileURL: url, result: .failure(error), header: nil)
            }
            entry.extensionID = extensionID
            entry.extensionDirectory = folder
            entry.extensionIcon = icon
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

    /// The modification date of each manifest and palette of the installed
    /// extensions. For a symbolic link (from a dotfiles manager), this is the
    /// date of the target, because the date of the link does not change when
    /// you save the file that it points at.
    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    private static func iconKey(_ url: URL) -> String {
        "icon:\(url.path)"
    }

    private func currentFingerprint() -> [String: Date] {
        var dates: [String: Date] = [:]
        func record(_ url: URL, as key: String) {
            dates[key] = Self.modificationDate(url)
        }
        for folder in Self.extensionFolders(in: extensionsURL) {
            let id = folder.lastPathComponent
            record(folder.appendingPathComponent(MactermExtension.manifestName), as: "extensions/\(id)")
            record(folder.appendingPathComponent(MactermExtension.sourceName), as: "extensions/\(id)/\(MactermExtension.sourceName)")
            let palettes = folder.appendingPathComponent(MactermExtension.palettesFolder, isDirectory: true)
            for url in Self.paletteFiles(in: palettes) {
                record(url, as: "extensions/\(id)/\(url.lastPathComponent)")
            }
            // Every other file too (a README, a script), so that an edit
            // anywhere in the folder updates `InstalledExtension.files`.
            let enumerator = FileManager.default.enumerator(
                at: folder.resolvingSymlinksInPath(),
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            while let url = enumerator?.nextObject() as? URL {
                record(url, as: "extensions/\(id)/files/\(url.path)")
            }
        }
        for url in iconFiles {
            record(url, as: Self.iconKey(url))
        }
        return dates
    }
}
