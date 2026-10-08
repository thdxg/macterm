import Foundation
import Yams

/// An extension: a folder of `extensions/` in Macterm's repository, named by
/// its id, holding `extension.yaml` (who maintains it), `palette.yaml` (the
/// palette) and `README.md`, and installed whole into
/// `~/.config/macterm/extensions/<id>/` (`PaletteRegistry`). The palette's
/// commands reach the folder's other files through `MACTERM_EXTENSION_DIR`.
enum MactermExtension {
    static let manifestName = "extension.yaml"
    static let paletteName = "palette.yaml"
    static let readmeName = "README.md"
    /// Where an installed extension's commands find its folder.
    static let directoryVariable = "MACTERM_EXTENSION_DIR"
    static let maxFileSize = 500_000
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]

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

    /// A README's first paragraph, for the gallery: the first block of text
    /// that isn't a heading, its lines joined.
    static func summary(readme: String) -> String? {
        let paragraphs = readme.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("![") }
        return paragraphs.first?.split(separator: "\n").joined(separator: " ")
    }
}

/// `extension.yaml`: the extension as a whole, as opposed to its palette —
/// for now who maintains it, by GitHub username; later its version and the
/// Macterm versions it supports.
struct ExtensionManifest: Codable, Equatable {
    var authors: [String]

    static let keys: Set<String> = ["authors"]

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
        guard !manifest.authors.isEmpty else {
            throw CustomPaletteError.invalid("\(MactermExtension.manifestName): authors: name at least one GitHub username")
        }
        for author in manifest.authors where !isGitHubUsername(author) {
            throw CustomPaletteError.invalid("\(MactermExtension.manifestName): authors: \(author) isn't a GitHub username")
        }
        return manifest
    }

    /// GitHub's rule: letters, digits and single hyphens, not at either end,
    /// at most 39 characters.
    static func isGitHubUsername(_ name: String) -> Bool {
        name.count <= 39 && name.wholeMatch(of: #/[A-Za-z0-9]+(-[A-Za-z0-9]+)*/#) != nil
    }
}
