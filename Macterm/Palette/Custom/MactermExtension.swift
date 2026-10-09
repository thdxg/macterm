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

    /// Where an extension keeps its screenshots, and what they must be: PNGs
    /// of exactly `screenshotPixelSize`, at most `maxScreenshots` of them, so
    /// every extension's look the same size in the gallery whatever the theme
    /// behind them. The size is the command palette framed with room around
    /// it at 2x (`screenshotPointSize`) — what Capture Palette Screenshot
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

/// `extension.yaml`: the extension as a whole, as opposed to its
/// capabilities — what the gallery shows (name, description, icon) and who
/// maintains it, by GitHub username.
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
