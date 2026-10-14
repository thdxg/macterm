import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "MactermConfigFile")

/// `~/.config/macterm/config.ghostty`: a config file of the user's own that
/// Macterm seeds and lists for them. At the first launch that finds it
/// missing, Macterm writes it as a template — every line of
/// `MactermConfig.defaults` commented out, each under a note that says what
/// it does — and, one time per install, appends it to the custom config files
/// of Settings → General → Ghostty Config (`Preferences.addMactermConfigFileOnce`).
/// From then on it is a custom file like any other: it loads after the
/// Ghostty default files, in its place in the list, and the user can move it
/// or remove it there. Ghostty.app never reads it, so a key in it applies to
/// Macterm alone; last in the list, it wins over the Ghostty config.
///
/// A commented line changes nothing, so the template is inert until the user
/// uncomments a key — the defaults layer (`macterm-defaults.conf`) stays the
/// single source of each default, and a key the user set in their Ghostty
/// config keeps winning. The file is a discoverable, editable listing of the
/// defaults, not their home: a user who deletes it, or installed before a
/// default was added, loses nothing.
///
/// Macterm never writes it again: an absent file means "no input", and a
/// present one belongs to the user. Open Macterm Config seeds it again
/// before it opens the editor, so a deleted file comes back as the template
/// on request only — and it never puts the row back, because a removed row
/// was the user's choice.
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

    /// The path as it goes into the custom config files: `~`-abbreviated,
    /// as the user would type it and as every row shows it. A file outside
    /// the home directory (a throwaway `HOME`) keeps its absolute path,
    /// because `~` expands through the user record, not `$HOME`.
    nonisolated static func listedPath(for url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// True when a custom path of `selection` names the file at `url`.
    nonisolated static func isListed(_ url: URL, in selection: GhosttyConfigSelection) -> Bool {
        selection.customPaths.contains { ($0 as NSString).expandingTildeInPath == url.path }
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
        "# Macterm wrote this file the first time that it started, and added it to",
        "# its config files in Settings > General > Ghostty Config. Macterm loads",
        "# it after your Ghostty config. A key in this file wins over the same key",
        "# in your Ghostty config, and it applies only to Macterm. Ghostty does",
        "# not read this file. You can move or remove it in Settings like any other",
        "# config file.",
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
