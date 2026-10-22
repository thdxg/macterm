import CryptoKit
import Foundation
import Yams

/// An extension: what a user installs. A folder named by its id, holding
/// `extension.yaml` (its name, description and authors — `ExtensionManifest`),
/// a `README.md`, and its capabilities — for now palettes, any number of
/// them, each a YAML file in `palettes/` with its own name and description.
/// Installed whole into `~/.config/macterm/extensions/<id>/`
/// (`PaletteRegistry`); its commands reach the folder's other files through
/// `MACTERM_EXTENSION_DIR`. A later capability is another folder beside
/// `palettes/`.
enum MactermExtension {
    static let manifestName = "extension.yaml"
    /// The record of where an installed extension came from
    /// (`ExtensionSource`). Install writes it. A folder without it is the
    /// user's own.
    static let sourceName = ".source.json"
    static let palettesFolder = "palettes"
    static let readmeName = "README.md"
    /// Where an installed extension's commands find its folder.
    static let directoryVariable = "MACTERM_EXTENSION_DIR"
    static let maxFileSize = 500_000
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
    static let defaultIcon = "puzzlepiece.extension"

    /// An id: lowercase words joined by `-`.
    static func isID(_ id: String) -> Bool {
        id.wholeMatch(of: #/[a-z0-9]+(-[a-z0-9]+)*/#) != nil
    }

    static func isImage(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The edge of an icon file, in pixels: a square PNG. The card in
    /// Settings, a pill and a palette row draw it at 16 to 20 points. At 2x,
    /// that is at most 40 pixels, so 128 leaves room for a larger glyph
    /// later. One exact size makes every bundled icon look the same.
    static let iconPixelSize = 128

    /// Whether the `icon` of a manifest names a file in the extension's
    /// folder and not an SF Symbol: the value ends in `.png`. No SF Symbol
    /// name does.
    static func isIconFile(_ icon: String) -> Bool {
        (icon as NSString).pathExtension.lowercased() == "png"
    }

    /// Whether an icon file's path stays inside the extension's folder:
    /// relative, with no `..` and no empty part.
    static func isIconPath(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// What an extension shows as its icon: its SF Symbol, its icon file, or
    /// the default. `file` reads a file of the extension by its path. An
    /// icon file that is missing or not a PNG of exactly `iconPixelSize`
    /// gives the default icon and the reason.
    static func icon(of manifest: ExtensionManifest?, file: (String) -> Data?) -> (icon: PaletteIcon, problem: String?) {
        guard let name = manifest?.icon else { return (.symbol(defaultIcon), nil) }
        guard isIconFile(name) else { return (.symbol(name), nil) }
        guard let data = file(name) else { return (.symbol(defaultIcon), "icon: no file \(name)") }
        guard let size = pngSize(data), size.width == iconPixelSize, size.height == iconPixelSize else {
            return (.symbol(defaultIcon), "icon: \(name) is not a PNG of \(iconPixelSize)×\(iconPixelSize) pixels")
        }
        return (.image(data), nil)
    }

    /// Where an extension keeps its screenshots, and what they must be: PNGs
    /// of exactly `screenshotPixelSize`, at most `maxScreenshots` of them, so
    /// every extension's look the same size in the gallery whatever the theme
    /// behind them. The size is the command palette framed with room around
    /// it at 2x (`screenshotPointSize`) — what Capture Palette
    /// (`PaletteScreenshot`) writes, as Raycast's Window Capture writes its
    /// store's 2000×1250.
    static let screenshotsFolder = "screenshots"
    static let screenshotPointSize = CGSize(width: 800, height: 500)
    static let screenshotPixelSize = (width: 1600, height: 1000)
    static let maxScreenshots = 6
    /// The space above the palette (its breadcrumb row included) in a
    /// screenshot; the rest of the height falls below it.
    static let screenshotTopMargin: CGFloat = 36

    static func isScreenshot(_ path: String) -> Bool {
        path.hasPrefix(screenshotsFolder + "/") && (path as NSString).pathExtension.lowercased() == "png"
            && !path.dropFirst(screenshotsFolder.count + 1).contains("/")
    }

    /// The screenshots that the card of an extension shows, from the paths
    /// of its files: the order that its README shows them in, then the
    /// others by name, at most `maxScreenshots`. The README of each
    /// extension shows its main screen first, and a file name says nothing
    /// about the order (`branch.png` sorts before `branches.png`).
    static func screenshots(in paths: some Sequence<String>, readme: String?) -> [String] {
        let all = Set(paths.filter(isScreenshot))
        var ordered: [String] = []
        for match in (readme ?? "").matches(of: #/screenshots/[^\s)"'>]+/#) {
            let path = String(match.output)
            if all.contains(path), !ordered.contains(path) { ordered.append(path) }
        }
        ordered += all.subtracting(ordered).sorted()
        return Array(ordered.prefix(maxScreenshots))
    }

    /// The part of the screen a screenshot of a palette at `palette` shows,
    /// both in AppKit's screen coordinates: `screenshotPointSize`, centred on
    /// the palette across, `screenshotTopMargin` above it, and moved onto
    /// `screen` where it would run off an edge.
    static func screenshotRect(around palette: CGRect, in screen: CGRect) -> CGRect {
        let size = screenshotPointSize
        var rect = CGRect(
            x: palette.midX - size.width / 2,
            y: palette.maxY + screenshotTopMargin - size.height,
            width: size.width,
            height: size.height
        )
        rect.origin.x = min(max(rect.minX, screen.minX), screen.maxX - size.width)
        rect.origin.y = min(max(rect.minY, screen.minY), screen.maxY - size.height)
        return rect
    }

    /// A PNG's width and height, read from its header; nil when `data` isn't
    /// a PNG.
    static func pngSize(_ data: Data) -> (width: Int, height: Int)? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24, Array(bytes[0 ..< 8]) == signature, bytes[12 ..< 16].elementsEqual("IHDR".utf8) else { return nil }
        let int = { (at: Int) in bytes[at ..< at + 4].reduce(0) { $0 << 8 | Int($1) } }
        return (int(16), int(20))
    }

    /// The first `screenshot-<n>.png` not taken in `folder`.
    static func nextScreenshotName(in folder: URL) -> String {
        var index = 1
        while FileManager.default.fileExists(atPath: folder.appendingPathComponent("screenshot-\(index).png").path) {
            index += 1
        }
        return "screenshot-\(index).png"
    }

    /// Whether `path` (relative to the extension's folder) is one of its
    /// palettes: a `.yaml` or `.yml` directly in `palettes/`.
    static func isPalette(_ path: String) -> Bool {
        let prefix = palettesFolder + "/"
        guard path.hasPrefix(prefix) else { return false }
        let name = path.dropFirst(prefix.count)
        return !name.contains("/") && ["yaml", "yml"].contains((String(name) as NSString).pathExtension.lowercased())
    }

    /// The id a palette of extension `id` goes by — in bindings, the CLI and
    /// every lookup: `<extension>/<file stem>`, so the palettes of two
    /// extensions never share an id.
    static func paletteID(extensionID id: String, path: String) -> String {
        "\(id)/\(((path as NSString).lastPathComponent as NSString).deletingPathExtension)"
    }

    /// A README's first paragraph, for the gallery: the first block of text
    /// that isn't a heading, its lines joined.
    static func summary(readme: String) -> String? {
        let paragraphs = readme.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("![") }
        return paragraphs.first?.split(separator: "\n").joined(separator: " ")
    }
}

/// Where an installed extension came from: the repository, and each of its
/// files as Install wrote it, by path, as a Git blob SHA. Install writes it
/// to `MactermExtension.sourceName` in the folder of the extension. With it,
/// Macterm can tell two things without Git: whether the user changed the
/// copy (the files on disk differ from `files`), and whether the repository
/// changed it (the tree of `main` differs from `files`). Uninstall moves it
/// to the Trash with the folder. A user who deletes it makes the copy their
/// own.
struct ExtensionSource: Codable, Equatable {
    var repository: String
    var ref: String
    var files: [String: String]

    static func read(in folder: URL) -> ExtensionSource? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(MactermExtension.sourceName)) else { return nil }
        return try? JSONDecoder().decode(ExtensionSource.self, from: data)
    }

    func write(in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(MactermExtension.sourceName))
    }

    /// The Git blob SHA of `data`, as the Git Trees API reports it for a file:
    /// SHA-1 of `blob <size>\0` and the bytes.
    static func blobSHA(_ data: Data) -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(data.count)\0".utf8))
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Every file in `folder` that is not hidden, by path, as a Git blob SHA.
    /// Hidden files (the source record, `.DS_Store`) are not part of an
    /// extension.
    static func files(in folder: URL) -> [String: String] {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var files: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(
            at: folder.resolvingSymlinksInPath(),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url)
            else { continue }
            files[String(url.standardizedFileURL.path.dropFirst(root.count))] = blobSHA(data)
        }
        return files
    }
}

/// `extension.yaml`: the extension as a whole, as opposed to its
/// capabilities — what the gallery shows (name, description, icon) and who
/// maintains it, by GitHub username. The icon is an SF Symbol name, or the
/// path of a PNG in the extension's folder (`MactermExtension.icon(of:file:)`).
/// The card and every palette of the extension show it.
struct ExtensionManifest: Codable, Equatable {
    var name: String
    var description: String
    var icon: String?
    /// The GitHub usernames of the maintainers. Optional for an extension
    /// that you write for yourself. `CustomPaletteFileTests` requires it for
    /// each extension in the repository.
    var authors: [String]

    init(name: String, description: String, icon: String? = nil, authors: [String] = []) {
        self.name = name
        self.description = description
        self.icon = icon
        self.authors = authors
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decode(String.self, forKey: .description)
        icon = try container.decodeIfPresent(String.self, forKey: .icon)
        authors = try container.decodeIfPresent([String].self, forKey: .authors) ?? []
    }

    static let keys: Set<String> = ["name", "description", "icon", "authors"]

    static func parse(yaml: String) throws -> ExtensionManifest {
        let manifest: ExtensionManifest
        do {
            manifest = try YAMLDecoder().decode(ExtensionManifest.self, from: yaml)
        } catch {
            throw CustomPaletteError.parse(underlying: error)
        }
        if let root = (try? Yams.load(yaml: yaml, Resolver.basic.appending(.merge))) as? [String: Any],
           let stray = root.keys.filter({ !keys.contains($0) && $0 != "<<" }).min()
        {
            throw CustomPaletteError.invalid("\(MactermExtension.manifestName): \(stray): no such key")
        }
        let file = MactermExtension.manifestName
        if manifest.name.trimmingCharacters(in: .whitespaces).isEmpty { throw CustomPaletteError.invalid("\(file): name: is empty") }
        if manifest.description.trimmingCharacters(in: .whitespaces).isEmpty {
            throw CustomPaletteError.invalid("\(file): description: is empty")
        }
        if let icon = manifest.icon, MactermExtension.isIconFile(icon), !MactermExtension.isIconPath(icon) {
            throw CustomPaletteError.invalid("\(file): icon: \(icon) is not a path inside the extension folder")
        }
        for author in manifest.authors where !isGitHubUsername(author) {
            throw CustomPaletteError.invalid("\(file): authors: \(author) is not a GitHub username")
        }
        return manifest
    }

    /// GitHub's rule: letters, digits and single hyphens, not at either end,
    /// at most 39 characters.
    static func isGitHubUsername(_ name: String) -> Bool {
        name.count <= 39 && name.wholeMatch(of: #/[A-Za-z0-9]+(-[A-Za-z0-9]+)*/#) != nil
    }
}
