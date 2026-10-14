import Foundation
@testable import Macterm
import Testing

/// Pins the contract of `~/.config/macterm/config.ghostty`: the seeded
/// template is inert (every line a comment), it lists every default exactly
/// as `macterm-defaults.conf` states it, and seeding never touches a file
/// that is already there.
@MainActor
struct MactermConfigFileTests {
    // MARK: - template

    /// The file loads after the user's Ghostty config, so an uncommented key
    /// would override their config in silence. Every line must be a comment
    /// or empty.
    @Test
    func template_sets_nothing() {
        for line in MactermConfigFile.template.split(separator: "\n", omittingEmptySubsequences: false) {
            #expect(line.isEmpty || line.hasPrefix("#"), "line is not a comment: \(line)")
        }
    }

    /// Each default appears as its own commented line, byte for byte the line
    /// of the defaults layer, under a note that says what it does.
    @Test
    func template_lists_every_default_with_its_note() {
        let template = MactermConfigFile.template
        for item in MactermConfig.defaults {
            #expect(template.contains("\n# \(item.line)\n"), "missing: \(item.line)")
            let firstNoteLine = item.note.split(separator: "\n").first.map(String.init) ?? ""
            #expect(template.contains("# \(firstNoteLine)\n"), "missing note for: \(item.line)")
            #expect(!item.note.isEmpty)
        }
        #expect(MactermConfig.defaultsBody == MactermConfig.defaults.map(\.line).joined(separator: "\n") + "\n")
    }

    /// The header tells the user the load order and the reload command.
    @Test
    func template_explains_the_load_order() {
        let template = MactermConfigFile.template
        #expect(template.hasPrefix("# Macterm config\n"))
        #expect(template.contains("after your Ghostty config"))
        #expect(template.contains("Reload Ghostty Config"))
    }

    // MARK: - seedIfMissing

    @Test
    func seeds_the_template_and_its_directory_once() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configDirectory = root.appendingPathComponent("config/macterm", isDirectory: true)
        let url = MactermConfigFile.url(in: configDirectory)

        #expect(MactermConfigFile.seedIfMissing(at: url))
        #expect(try String(contentsOf: url, encoding: .utf8) == MactermConfigFile.template)
        #expect(url.lastPathComponent == "config.ghostty")

        // A second seed is a no-op, and the file keeps the user's edits.
        try Data("font-size = 18\n".utf8).write(to: url)
        #expect(!MactermConfigFile.seedIfMissing(at: url))
        #expect(try String(contentsOf: url, encoding: .utf8) == "font-size = 18\n")
    }

    /// `attributesOfItem` does not follow links, and the write refuses to
    /// overwrite, so a link whose target is gone stays a link.
    @Test
    func leaves_a_dangling_symlink_alone() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = MactermConfigFile.url(in: root)
        try FileManager.default.createSymbolicLink(
            at: url,
            withDestinationURL: root.appendingPathComponent("missing.ghostty")
        )

        #expect(!MactermConfigFile.seedIfMissing(at: url))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
    }

    @Test
    func default_url_is_the_config_directory_file() {
        let url = MactermConfigFile.defaultURL()
        #expect(url.lastPathComponent == "config.ghostty")
        #expect(url.deletingLastPathComponent().path.hasSuffix("/.config/macterm"))
        #expect(url.deletingLastPathComponent().standardizedFileURL
            == ProjectFileStore.defaultConfigDirectory().standardizedFileURL)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MactermConfigFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
