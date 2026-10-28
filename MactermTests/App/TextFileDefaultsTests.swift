import Foundation
@testable import Macterm
import Testing
import UniformTypeIdentifiers

/// Make Default sets one Launch Services default for each type in this list,
/// so a type in it that is not text would take a file that no editor can open
/// (a video, a web page) away from its app.
struct TextFileDefaultsTests {
    @Test
    func the_plists_extensions_are_read_in_order() {
        let info: [String: Any] = [
            "CFBundleDocumentTypes": [
                ["LSItemContentTypes": ["public.directory"]],
                ["CFBundleTypeExtensions": ["go", "rs"]],
                ["CFBundleTypeExtensions": ["zig"]],
            ],
        ]
        #expect(TextFileDefaults.declaredExtensions(in: info) == ["go", "rs", "zig"])
        #expect(TextFileDefaults.declaredExtensions(in: nil).isEmpty)
    }

    @Test
    func only_text_and_unknown_extensions_are_kept_once() throws {
        let unknown = try #require(UTType(filenameExtension: "macterm-test-unknown"))
        let types: [String: UTType] = [
            "txt": .plainText,
            "text": .plainText,
            "py": .pythonScript,
            "html": .html,
            "rtf": .rtf,
            "svg": .svg,
            "ts": .mpeg2TransportStream,
            "png": .png,
            "unknown": unknown,
        ]
        let kept = TextFileDefaults.contentTypes(
            forExtensions: ["txt", "html", "py", "text", "rtf", "svg", "ts", "png", "unknown", "missing"],
            type: { types[$0] }
        )
        #expect(kept.map(\.identifier) == [UTType.plainText.identifier, UTType.pythonScript.identifier, unknown.identifier])
    }

    @Test
    func the_apps_list_covers_text_and_the_declared_source_files() throws {
        let identifiers = Set(TextFileDefaults.contentTypes().map(\.identifier))
        #expect(identifiers.contains(UTType.plainText.identifier))
        #expect(identifiers.contains(UTType.pythonScript.identifier))
        #expect(identifiers.contains(UTType.swiftSource.identifier))
        #expect(!identifiers.contains(UTType.html.identifier))
        #expect(!identifiers.contains(UTType.mpeg2TransportStream.identifier))
        let go = try #require(UTType(filenameExtension: "go"))
        #expect(identifiers.contains(go.identifier))
    }

    /// The docs table of the extensions that Make Default changes, read
    /// from the source tree, so that a new extension in the plist or in
    /// `commonExtensions` fails here until the docs list it.
    @Test
    func the_docs_list_every_extension_that_the_button_changes() throws {
        let page = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // App
            .deletingLastPathComponent() // MactermTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("website/docs/pages/20-configuration.md")
        let text = try String(contentsOf: page, encoding: .utf8)
        let start = try #require(text.range(of: "### File types that Make Default changes"))
        let rest = text[start.upperBound...]
        let section = rest[..<(rest.range(of: "\n#")?.lowerBound ?? rest.endIndex)]
        let tableRows = section.split(separator: "\n").filter { $0.hasPrefix("| ") }
        let documented = tableRows.flatMap { row in
            row.matches(of: #/`\.([A-Za-z0-9]+)`/#).map { String($0.output.1) }
        }
        #expect(documented.count == Set(documented).count, "an extension is in the docs table twice")
        #expect(Set(documented) == Set(TextFileDefaults.extensions()))
    }

    @Test
    func a_type_opened_by_another_app_or_by_none_is_not_opened_here() {
        let defaults: [String: URL] = [
            UTType.plainText.identifier: Bundle.main.bundleURL,
            UTType.json.identifier: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
        ]
        let missing = TextFileDefaults.typesNotOpenedHere(
            [.plainText, .json, .pythonScript],
            bundleIdentifier: Bundle.main.bundleIdentifier,
            defaultApp: { defaults[$0.identifier] }
        )
        #expect(missing == [.json, .pythonScript])
    }
}
