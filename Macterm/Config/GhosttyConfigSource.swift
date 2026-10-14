import Foundation

struct GhosttyConfigSelection: Equatable {
    var loadsDefaultFiles: Bool
    var customPaths: [String]

    static let automatic = Self(loadsDefaultFiles: true, customPaths: [])
    static let disabled = Self(loadsDefaultFiles: false, customPaths: [])
}

/// Loads the selected config and exposes the same root files to raw-text
/// consumers: the Ghostty files the selection names, then — when the caller
/// passes it — `~/.config/macterm/config.ghostty` (`MactermConfigFile`), the
/// Macterm-only layer that loads after all of them.
struct GhosttyConfigSource {
    struct DefaultFileLocation: Equatable, Identifiable {
        let searchedPath: String
        let resolvedPath: String?

        var id: String { searchedPath }
    }

    static let applicationSupportConfigDirectory =
        "~/Library/Application Support/com.mitchellh.ghostty"
    static let fallbackXDGConfigDirectory = "~/.config/ghostty"
    private static let xdgSubdirectory = "ghostty"
    private static let currentConfigFilename = "config.ghostty"
    private static let legacyConfigFilename = "config"

    let selection: GhosttyConfigSelection
    /// The Macterm-only file, loaded after every file of `selection`. nil
    /// leaves it out: a hermetic run (`MactermConfig.userConfigPath`), or a
    /// test of the Ghostty layers alone. It is not part of `selection`,
    /// because the selection is the user's preference about the Ghostty
    /// files, and turning those off must not turn this one off.
    let mactermConfigPath: String?
    let applicationSupportConfigDirectory: String
    let xdgConfigDirectory: String

    init(
        selection: GhosttyConfigSelection,
        mactermConfigPath: String? = nil,
        applicationSupportConfigDirectory: String = Self.expandedApplicationSupportConfigDirectory,
        xdgConfigDirectory: String = Self.expandedXDGConfigDirectory
    ) {
        self.selection = selection
        self.mactermConfigPath = mactermConfigPath
        self.applicationSupportConfigDirectory = applicationSupportConfigDirectory
        self.xdgConfigDirectory = xdgConfigDirectory
    }

    /// Root files in last-wins load order: Ghostty's default files, the
    /// custom files, then the Macterm file.
    var pathsForRawInspection: [String] {
        let defaultPaths = selection.loadsDefaultFiles
            ? Self.defaultFilePaths(
                applicationSupportConfigDirectory: applicationSupportConfigDirectory,
                xdgConfigDirectory: xdgConfigDirectory
            )
            : []
        return defaultPaths
            + selection.customPaths.map { ($0 as NSString).expandingTildeInPath }
            + (mactermConfigPath.map { [$0] } ?? [])
    }

    /// Loads the selected layers and returns any missing custom paths. The
    /// Macterm file loads last through the same closure; it is never
    /// reported, because the user can delete it and an absent file means
    /// "no input".
    func load(
        loadDefaultFiles: () -> Void,
        loadCustomFile: (String) -> Bool
    ) -> [String] {
        if selection.loadsDefaultFiles {
            loadDefaultFiles()
        }
        let missing = selection.customPaths.compactMap { path in
            let expandedPath = (path as NSString).expandingTildeInPath
            return loadCustomFile(expandedPath) ? nil : expandedPath
        }
        if let mactermConfigPath {
            _ = loadCustomFile(mactermConfigPath)
        }
        return missing
    }

    /// Joins readable root files with a newline so adjacent settings cannot merge.
    func mergedText() -> String? {
        mergedText(read: Self.readFile)
    }

    func mergedText(read: (String) throws -> String) -> String? {
        let texts = pathsForRawInspection.compactMap { try? read($0) }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    static func defaultFilePaths(
        applicationSupportConfigDirectory: String,
        xdgConfigDirectory: String
    ) -> [String] {
        [
            (xdgConfigDirectory as NSString).appendingPathComponent(legacyConfigFilename),
            (xdgConfigDirectory as NSString).appendingPathComponent(currentConfigFilename),
            (applicationSupportConfigDirectory as NSString).appendingPathComponent(legacyConfigFilename),
            (applicationSupportConfigDirectory as NSString).appendingPathComponent(currentConfigFilename),
        ]
    }

    /// Every default location Ghostty checks, paired with the regular file it
    /// resolves to. A nil target means the candidate is missing or not a file.
    static func defaultFileLocations(
        applicationSupportConfigDirectory: String = Self.expandedApplicationSupportConfigDirectory,
        xdgConfigDirectory: String = Self.expandedXDGConfigDirectory,
        resolveRegularFile: (String) -> String? = Self.resolvedRegularFilePath
    ) -> [DefaultFileLocation] {
        defaultFilePaths(
            applicationSupportConfigDirectory: applicationSupportConfigDirectory,
            xdgConfigDirectory: xdgConfigDirectory
        ).map { path in
            DefaultFileLocation(searchedPath: path, resolvedPath: resolveRegularFile(path))
        }
    }

    private static var expandedApplicationSupportConfigDirectory: String {
        (applicationSupportConfigDirectory as NSString).expandingTildeInPath
    }

    private static var expandedXDGConfigDirectory: String {
        ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { directory in
            guard !directory.isEmpty else { return nil }
            return (directory as NSString).appendingPathComponent(xdgSubdirectory)
        } ?? (fallbackXDGConfigDirectory as NSString).expandingTildeInPath
    }

    private static func readFile(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    private static func resolvedRegularFilePath(_ path: String) -> String? {
        let resolvedURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { return nil }
        return resolvedURL.path(percentEncoded: false)
    }
}
