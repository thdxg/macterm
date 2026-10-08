import Foundation
@testable import Macterm
import Testing

/// Every Settings help button must land on a heading that exists. The pages
/// are read from the source tree and their anchors derived the way
/// `website/build-docs.mjs` derives them, so renaming a heading fails here
/// rather than leaving a button that opens the top of a page.
struct DocsLinkTests {
    private static let pagesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Settings
        .deletingLastPathComponent() // MactermTests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("website/docs/pages")

    /// `slugifyHeading` in build-docs.mjs.
    private static func anchor(for heading: String) -> String {
        var text = heading.lowercased()
        text = text.replacing(#/<[^>]*>/#, with: "")
        text = text.replacing(#/&[a-z]+;/#, with: "")
        text = String(text.unicodeScalars.filter {
            ("a" ... "z").contains($0) || ("0" ... "9").contains($0) || $0 == " " || $0 == "-"
                || CharacterSet.whitespaces.contains($0)
        }.map(Character.init))
        return text.trimmingCharacters(in: .whitespaces)
            .replacing(#/\s+/#, with: "-")
    }

    /// The anchors of one page's headings, by its front-matter slug.
    private static func anchors(onPage slug: String) throws -> [String] {
        let files = try FileManager.default.contentsOfDirectory(at: pagesDirectory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension == "md" {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("slug: \(slug)\n") else { continue }
            return text.split(separator: "\n").compactMap { line in
                guard let match = line.firstMatch(of: #/^#{1,6}\s+(.+)$/#) else { return nil }
                return anchor(for: String(match.output.1))
            }
        }
        return []
    }

    @Test
    func every_section_points_at_a_page_and_heading_that_exist() throws {
        for section in DocsSection.allCases {
            let anchors = try Self.anchors(onPage: section.page)
            #expect(!anchors.isEmpty, "no docs page with slug \(section.page)")
            if let anchor = section.anchor {
                #expect(anchors.contains(anchor), "\(section) → no heading with anchor \(anchor)")
            }
        }
    }

    @Test
    func anchors_follow_the_docs_build() {
        #expect(Self.anchor(for: "Open files in your terminal editor") == "open-files-in-your-terminal-editor")
        #expect(Self.anchor(for: "Keys with no Settings equivalent") == "keys-with-no-settings-equivalent")
        #expect(Self.anchor(for: "Running `macterm` (the CLI)") == "running-macterm-the-cli")
    }

    @Test
    func the_url_is_the_page_and_anchor_on_the_docs_site() {
        #expect(DocsSection.textFiles.url.absoluteString
            == "https://macterm.thdxg.dev/docs/configuration#open-files-in-your-terminal-editor")
        #expect(DocsSection.passwords.url.absoluteString == "https://macterm.thdxg.dev/docs/passwords")
        #expect(DocsSection.passwords.anchor == nil)
        // An arrow in a heading drops out, as in the docs build.
        #expect(Self.anchor(for: "Settings → Password Manager") == "settings-password-manager")
    }
}
