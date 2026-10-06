import Foundation

/// The pure half of "open something WITH Macterm": what the URLs AppKit hands
/// `AppDelegate.application(_:open:)` become.
///
/// Finder's "Open With", a drop on the Dock icon and `open -a Macterm <path>`
/// all arrive here as document URLs. A folder means a project — never a tab,
/// never a `cd` into an existing one — because it is the same gesture as the
/// folder picker and the Finder service, and those always add one. A file
/// means the user's terminal editor (`TextFileEditor`), opened in the project
/// that holds it (`TextFileProject`); the plist offers Macterm for text files,
/// but `open -a` accepts anything, and a file it was pointed at is still a
/// file the user asked to open.
enum DocumentOpenRequest {
    struct Resolution: Equatable {
        /// Canonical local paths of the folders to open, in delivery order,
        /// one per distinct directory.
        var directories: [String] = []
        /// Standardized local paths of the files to open, in delivery order,
        /// one per distinct file.
        var files: [String] = []
        /// Everything that was not a local file or folder, for the log.
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
            guard url.isFileURL else {
                resolution.skipped.append(url)
                continue
            }
            if isDirectory(url) {
                let path = ProjectPath.canonicalLocal(url.path(percentEncoded: false))
                if seen.insert(path).inserted {
                    resolution.directories.append(path)
                }
            } else {
                let path = (url.path(percentEncoded: false) as NSString).standardizingPath
                if seen.insert(path).inserted {
                    resolution.files.append(path)
                }
            }
        }
        return resolution
    }
}

/// Which project a text file opened from outside the app belongs in: the
/// local project whose directory holds it most closely, else the active
/// project when it is local, else the first local one. nil when there is no
/// local project at all — the caller then makes one for the file's folder,
/// the same way opening that folder would. A remote project is never chosen:
/// the file is on this Mac, and a pane there would start on the host.
enum TextFileProject {
    static func project(for file: String, in projects: [Project], activeProjectID: UUID?) -> Project? {
        let local = projects.filter { !$0.isRemote }
        var closest: (project: Project, depth: Int)?
        for project in local {
            let directory = ProjectPath.canonicalLocal(project.path)
            guard contains(directory, file), directory.count > closest?.depth ?? -1 else { continue }
            closest = (project, directory.count)
        }
        if let closest { return closest.project }
        if let active = local.first(where: { $0.id == activeProjectID }) { return active }
        return local.first
    }

    /// Whether `file` is inside `directory` — by whole components, so
    /// `/a/bc/x` is not inside `/a/b`.
    private static func contains(_ directory: String, _ file: String) -> Bool {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return file.hasPrefix(prefix)
    }
}
