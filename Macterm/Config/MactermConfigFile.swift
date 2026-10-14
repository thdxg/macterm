import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "MactermConfigFile")

/// `~/.config/macterm/config.ghostty`: the user's own Macterm-only config
/// layer. `GhosttyApp.loadConfig` loads it after every Ghostty file and before
/// `macterm-overrides.conf`, so a key in it wins over the same key in the
/// Ghostty config and applies to Macterm alone (Ghostty.app never reads it).
///
/// Macterm writes it once, at the first launch that finds it missing, as a
/// template: every line of `MactermConfig.defaults` commented out, each under
/// a note that says what it does. A commented line changes nothing, so the
/// template is inert until the user uncomments a key — the defaults layer
/// (`macterm-defaults.conf`) stays the single source of each default, and the
/// Ghostty config keeps its promise that a key the user set there wins. The
/// file is therefore a discoverable, editable listing of the defaults, not
/// their home: a user who deletes it, or installed before a default was
/// added, loses nothing.
///
/// Macterm never writes it again: an absent file means "no input", and a
/// present one belongs to the user. Open Macterm Config seeds it again
/// before it opens the editor, so a deleted file comes back as the template
/// on request only.
enum MactermConfigFile {
    static let filename = "config.ghostty"

    /// The file inside `configDirectory` (`ProjectFileStore.configDirectoryURL`).
    nonisolated static func url(in configDirectory: URL) -> URL {
        configDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    /// The real file, under the user's `~/.config/macterm`.
    nonisolated static func defaultURL() -> URL {
        url(in: ProjectFileStore.defaultConfigDirectory())
    }

    /// The text Macterm seeds. Every non-empty line is a comment, so loading
    /// it sets nothing — `MactermConfigFileTests` pins that, and that each
    /// default appears exactly as `macterm-defaults.conf` states it.
    @MainActor
    static var template: String {
        var lines = Self.header
        for item in MactermConfig.defaults {
            lines.append("")
            for note in item.note.split(separator: "\n") {
                lines.append("# \(note)")
            }
            lines.append("# \(item.line)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static let header: [String] = [
        "# Macterm config",
        "#",
        "# Macterm wrote this file the first time that it started. Macterm loads",
        "# it after your Ghostty config. A key in this file wins over the same key",
        "# in your Ghostty config, and it applies only to Macterm. Ghostty does",
        "# not read this file.",
        "#",
        "# The lines below are the defaults of Macterm. Each one is a comment, so",
        "# it changes nothing. To change a value, remove the \"#\" at the start of",
        "# its line and edit the value. You can add any Ghostty key:",
        "# https://ghostty.org/docs/config/reference",
        "#",
        "# Macterm forces some keys, and they do nothing here: background-opacity,",
        "# background-blur, and the title bar, window decoration and split divider",
        "# keys. Set them in Settings. See https://macterm.thdxg.dev/docs/configuration",
        "#",
        "# To apply a change, run Reload Ghostty Config from the command palette.",
    ]

    /// Writes the template at `url` when nothing is there, and creates the
    /// directory above it. Returns true only when it wrote. Anything already
    /// at the path — a file, a directory, a symlink with or without a target
    /// — is left alone: `attributesOfItem` does not follow links, and the
    /// write itself refuses to overwrite, so a link that dangles can never be
    /// replaced by a file.
    @MainActor
    @discardableResult
    static func seedIfMissing(at url: URL = defaultURL()) -> Bool {
        let fileManager = FileManager.default
        if (try? fileManager.attributesOfItem(atPath: url.path)) != nil {
            return false
        }
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(template.utf8).write(to: url, options: .withoutOverwriting)
            logger.info("seeded \(url.path, privacy: .public)")
            return true
        } catch {
            logger.error("failed to seed \(url.path, privacy: .public): \(error, privacy: .public)")
            return false
        }
    }
}
