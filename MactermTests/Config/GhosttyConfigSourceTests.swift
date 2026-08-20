import Foundation
@testable import Macterm
import Testing

struct GhosttyConfigSourceTests {
    private let appSupport = "/Library/Application Support/com.mitchellh.ghostty"
    private let xdg = "/xdg/ghostty"

    @Test
    func automatic_paths_match_ghostty_root_file_load_order() {
        let source = GhosttyConfigSource(
            selection: .automatic,
            applicationSupportConfigDirectory: appSupport,
            xdgConfigDirectory: xdg
        )

        #expect(source.pathsForRawInspection == [
            "/xdg/ghostty/config",
            "/xdg/ghostty/config.ghostty",
            "/Library/Application Support/com.mitchellh.ghostty/config",
            "/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ])
    }

    @Test
    func automatic_loading_delegates_to_libghostty_seam() {
        let source = GhosttyConfigSource(
            selection: .automatic,
            applicationSupportConfigDirectory: appSupport,
            xdgConfigDirectory: xdg
        )
        var defaultLoadCount = 0
        var customPaths: [String] = []

        let missing = source.load(
            loadDefaultFiles: { defaultLoadCount += 1 },
            loadCustomFile: {
                customPaths.append($0)
                return true
            }
        )

        #expect(missing.isEmpty)
        #expect(defaultLoadCount == 1)
        #expect(customPaths.isEmpty)
    }

    @Test
    func raw_text_merges_readable_files_in_load_order() {
        let source = GhosttyConfigSource(
            selection: .automatic,
            applicationSupportConfigDirectory: appSupport,
            xdgConfigDirectory: xdg
        )
        let textByPath = [
            "/xdg/ghostty/config": "theme = xdg-legacy",
            "/xdg/ghostty/config.ghostty": "theme = xdg-current",
            "/Library/Application Support/com.mitchellh.ghostty/config.ghostty": "theme = app-current",
        ]

        let text = source.mergedText { path in
            guard let text = textByPath[path] else { throw CocoaError(.fileNoSuchFile) }
            return text
        }

        #expect(text == "theme = xdg-legacy\ntheme = xdg-current\ntheme = app-current")
    }

    @Test
    func custom_files_load_after_defaults_and_report_every_missing_path() {
        let source = GhosttyConfigSource(
            selection: GhosttyConfigSelection(
                loadsDefaultFiles: true,
                customPaths: ["/custom/first.ghostty", "/custom/second.ghostty"]
            ),
            applicationSupportConfigDirectory: appSupport,
            xdgConfigDirectory: xdg
        )
        var defaultLoadCount = 0
        var loadedPaths: [String] = []

        let missing = source.load(
            loadDefaultFiles: { defaultLoadCount += 1 },
            loadCustomFile: { path in
                loadedPaths.append(path)
                return false
            }
        )

        #expect(defaultLoadCount == 1)
        #expect(loadedPaths == ["/custom/first.ghostty", "/custom/second.ghostty"])
        #expect(missing == loadedPaths)
        #expect(source.pathsForRawInspection == [
            "/xdg/ghostty/config",
            "/xdg/ghostty/config.ghostty",
            "/Library/Application Support/com.mitchellh.ghostty/config",
            "/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
            "/custom/first.ghostty",
            "/custom/second.ghostty",
        ])
    }

    @Test
    func disabled_loading_has_no_paths_or_callbacks() {
        let source = GhosttyConfigSource(
            selection: .disabled,
            applicationSupportConfigDirectory: appSupport,
            xdgConfigDirectory: xdg
        )
        var callbackCount = 0

        let missing = source.load(
            loadDefaultFiles: { callbackCount += 1 },
            loadCustomFile: { _ in
                callbackCount += 1
                return true
            }
        )

        #expect(missing.isEmpty)
        #expect(callbackCount == 0)
        #expect(source.pathsForRawInspection.isEmpty)
        #expect(source.mergedText(read: { _ in "unexpected" }) == nil)
    }

    @Test
    func default_locations_report_checked_and_resolved_paths_in_load_order() {
        let locations = GhosttyConfigSource.defaultFileLocations(
            applicationSupportConfigDirectory: appSupport,
            xdgConfigDirectory: xdg,
            resolveRegularFile: { path in
                if path == "/xdg/ghostty/config.ghostty" {
                    return "/dotfiles/config.ghostty"
                }
                if path == "/Library/Application Support/com.mitchellh.ghostty/config" {
                    return path
                }
                return nil
            }
        )

        #expect(locations == [
            .init(searchedPath: "/xdg/ghostty/config", resolvedPath: nil),
            .init(searchedPath: "/xdg/ghostty/config.ghostty", resolvedPath: "/dotfiles/config.ghostty"),
            .init(
                searchedPath: "/Library/Application Support/com.mitchellh.ghostty/config",
                resolvedPath: "/Library/Application Support/com.mitchellh.ghostty/config"
            ),
            .init(
                searchedPath: "/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
                resolvedPath: nil
            ),
        ])
    }

    @Test
    func symlinked_default_paths_show_the_target_but_load_through_the_original_path() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-ghostty-config-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let xdgDirectory = root.appendingPathComponent("xdg", isDirectory: true)
        let appSupportDirectory = root.appendingPathComponent("app-support", isDirectory: true)
        let target = root.appendingPathComponent("dotfiles/config.ghostty")
        let link = xdgDirectory.appendingPathComponent("config.ghostty")
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: xdgDirectory, withIntermediateDirectories: true)
        try "theme = test".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let locations = GhosttyConfigSource.defaultFileLocations(
            applicationSupportConfigDirectory: appSupportDirectory.path,
            xdgConfigDirectory: xdgDirectory.path
        )

        let current = try #require(locations.first { $0.searchedPath == link.path })
        #expect(current.resolvedPath == target.resolvingSymlinksInPath().path)
        let source = GhosttyConfigSource(
            selection: .automatic,
            applicationSupportConfigDirectory: appSupportDirectory.path,
            xdgConfigDirectory: xdgDirectory.path
        )
        #expect(source.pathsForRawInspection.contains(link.path))
        #expect(source.mergedText() == "theme = test")

        var loadedPaths: [String] = []
        let customSource = GhosttyConfigSource(
            selection: GhosttyConfigSelection(loadsDefaultFiles: false, customPaths: [link.path]),
            applicationSupportConfigDirectory: appSupportDirectory.path,
            xdgConfigDirectory: xdgDirectory.path
        )
        let missing = customSource.load(
            loadDefaultFiles: {},
            loadCustomFile: { path in
                loadedPaths.append(path)
                return (try? String(contentsOfFile: path, encoding: .utf8)) == "theme = test"
            }
        )
        #expect(loadedPaths == [link.path])
        #expect(missing.isEmpty)
    }
}
