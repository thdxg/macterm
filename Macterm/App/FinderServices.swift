import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "FinderServices")

/// The pure half of the Finder service: which project directories a service
/// request names. Kept apart from the provider so it can be tested without a
/// pasteboard.
enum FinderServiceRequest {
    /// Canonical local paths for the distinct directories a Finder selection
    /// names, in selection order.
    ///
    /// A file resolves to the folder it sits in — "here" for a file is its
    /// parent, the reading Ghostty's own services take — and anything that is
    /// not a file URL is dropped. Two entries naming one directory (a folder
    /// and a file inside it, say) collapse to one, so one gesture never adds
    /// the same project twice.
    ///
    /// `isDirectory` is injectable because the real answer comes from the file
    /// system: an `NSURL` read off the pasteboard carries no trailing slash, so
    /// `hasDirectoryPath` alone would call every folder a file.
    static func projectPaths(
        from urls: [URL],
        isDirectory: (URL) -> Bool = defaultIsDirectory
    ) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for url in urls where url.isFileURL {
            let directory = isDirectory(url) ? url : url.deletingLastPathComponent()
            let path = ProjectPath.canonicalLocal(directory.path(percentEncoded: false))
            if seen.insert(path).inserted {
                paths.append(path)
            }
        }
        return paths
    }

    static func defaultIsDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? url.hasDirectoryPath
    }
}

/// `NSApp.servicesProvider` — the object AppKit hands a Finder "Services"
/// request to. Each `@objc` method here is an `NSMessage` in `Info.plist`'s
/// `NSServices` array; the selector name is the wire contract between the two
/// (`FinderServicesTests` pins it).
///
/// A request can arrive before the app is ready for it: choosing the service
/// while Macterm is not running launches it, and AppKit delivers the pending
/// message as soon as the provider is registered — which can be before
/// `MainWindow` has handed the delegate its state objects, and before the
/// launch task has restored the selection (which would then override the
/// project the request just selected). So a request is held until `attach`,
/// and then until `AppState.performWhenRestored` says the launch restore is
/// done.
@MainActor
final class FinderServiceProvider: NSObject {
    /// The `NSMessage` of the "New … Project Here" service. Renaming the method
    /// below means renaming this AND the plist entry.
    static let newProjectMessage = "newProjectHere"

    private weak var appState: AppState?
    private weak var projectStore: ProjectStore?
    /// Directories requested before `attach` ran.
    private var pending: [String] = []

    /// Hand the provider its targets once they exist (from
    /// `AppDelegate.installResponders`), flushing anything requested earlier.
    func attach(appState: AppState, projectStore: ProjectStore) {
        self.appState = appState
        self.projectStore = projectStore
        let queued = pending
        pending = []
        if !queued.isEmpty { open(paths: queued) }
    }

    /// "New Macterm Project Here": a project per selected folder, the last one
    /// selected and the window brought forward.
    @objc
    func newProjectHere(
        _ pasteboard: NSPasteboard,
        userData _: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let paths = FinderServiceRequest.projectPaths(from: urls)
        guard !paths.isEmpty else {
            error.pointee = "Select a folder in Finder to make it a \(appDisplayName) project." as NSString
            return
        }
        open(paths: paths)
    }

    /// Create a project for each directory and select the last, deferring
    /// until the app can act on it (see the type comment).
    func open(paths: [String]) {
        guard let appState, let projectStore else {
            pending.append(contentsOf: paths)
            return
        }
        appState.performWhenRestored { [weak appState, weak projectStore] in
            guard let appState, let projectStore else { return }
            logger.info("newProjectHere: \(paths.count, privacy: .public) directories")
            var selected: Project?
            for path in paths {
                // Always create, like the folder picker and `project create`:
                // a directory is not an identity, and a second project on the
                // same folder is a legitimate ask.
                selected = projectStore.create(name: (path as NSString).lastPathComponent, path: path)
            }
            if let selected {
                // The same first-open path as the sidebar — a matching central
                // project file auto-applies its layout.
                appState.selectProject(selected)
            }
            // The gesture happened in Finder, so Macterm is in the background
            // (or has no visible window, or was just launched); bring the
            // project the user asked for in front of them.
            appState.appDelegate?.showWindow()
        }
    }
}
