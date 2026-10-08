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
