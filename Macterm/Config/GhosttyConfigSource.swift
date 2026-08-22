import Foundation

struct GhosttyConfigSelection: Equatable {
    var loadsDefaultFiles: Bool
    var customPaths: [String]

    static let automatic = Self(loadsDefaultFiles: true, customPaths: [])
    static let disabled = Self(loadsDefaultFiles: false, customPaths: [])
}

/// Loads the selected config and exposes the same root files to raw-text consumers.
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
    let applicationSupportConfigDirectory: String
    let xdgConfigDirectory: String

    init(
        selection: GhosttyConfigSelection,
        applicationSupportConfigDirectory: String = Self.expandedApplicationSupportConfigDirectory,
        xdgConfigDirectory: String = Self.expandedXDGConfigDirectory
    ) {
        self.selection = selection
        self.applicationSupportConfigDirectory = applicationSupportConfigDirectory
        self.xdgConfigDirectory = xdgConfigDirectory
    }

    /// Root files in Ghostty's last-wins load order. The two modes are
    /// exclusive: default mode reads Ghostty's own locations, custom mode
    /// reads the user's list — never both.
    var pathsForRawInspection: [String] {
        if selection.loadsDefaultFiles {
            return Self.defaultFilePaths(
                applicationSupportConfigDirectory: applicationSupportConfigDirectory,
                xdgConfigDirectory: xdgConfigDirectory
            )
        }
        return selection.customPaths.map { ($0 as NSString).expandingTildeInPath }
    }

    /// Loads the selected mode and returns any missing custom paths. Default
    /// mode delegates entirely to libghostty's own default loader, so its
    /// file set, order, and merge are Ghostty's by construction; the stored
    /// custom paths are kept but not loaded.
    func load(
        loadDefaultFiles: () -> Void,
        loadCustomFile: (String) -> Bool
    ) -> [String] {
        if selection.loadsDefaultFiles {
            loadDefaultFiles()
            return []
        }
        return selection.customPaths.compactMap { path in
            let expandedPath = (path as NSString).expandingTildeInPath
            return loadCustomFile(expandedPath) ? nil : expandedPath
        }
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
