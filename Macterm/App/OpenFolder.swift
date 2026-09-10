import Foundation

/// The pure half of "open a folder with Macterm": which of the URLs AppKit
/// hands `AppDelegate.application(_:open:)` become projects.
///
/// Finder's "Open With", a drop on the Dock icon and `open -a Macterm <dir>`
/// all arrive here as document URLs. A folder means a project — never a tab,
/// never a `cd` into an existing one — because it is the same gesture as the
/// folder picker and the Finder service, and those always add one. A file is
/// **not** resolved to its folder the way the Services menu does it: the
/// Services item is offered on the file the user right-clicked, so "here"
/// has an obvious reading, whereas a file reaching this path means someone
/// bypassed the plist (`open -a` accepts anything), and guessing at its
/// folder would open a project nobody pointed at. Files are simply skipped,
/// and the caller logs them.
enum FolderOpenRequest {
    struct Resolution: Equatable {
        /// Canonical local paths of the folders to open, in delivery order,
        /// one per distinct directory.
        var directories: [String] = []
        /// Everything that was not a local directory, for the log.
        var skipped: [URL] = []
    }

    /// `isDirectory` is injectable because the real answer comes from the file
    /// system: a URL built from a path AppKit hands over carries no trailing
    /// slash, so `hasDirectoryPath` alone would call every folder a file.
    static func resolve(
        _ urls: [URL],
        isDirectory: (URL) -> Bool = FinderServiceRequest.defaultIsDirectory
    ) -> Resolution {
        var resolution = Resolution()
        var seen = Set<String>()
        for url in urls {
            guard url.isFileURL, isDirectory(url) else {
                resolution.skipped.append(url)
                continue
            }
            let path = ProjectPath.canonicalLocal(url.path(percentEncoded: false))
            if seen.insert(path).inserted {
                resolution.directories.append(path)
            }
        }
        return resolution
    }
}
