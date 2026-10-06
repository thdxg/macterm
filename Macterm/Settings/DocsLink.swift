import SwiftUI

/// A section of the website's docs that a Settings section points to, so the
/// explaining lives in the docs and Settings keeps one line of caption.
///
/// The raw value is the page slug plus the heading's anchor, which
/// `website/build-docs.mjs` derives from the heading text (lowercased, words
/// joined by hyphens). Renaming a heading moves its anchor;
/// `DocsLinkTests` reads the pages back and fails until the case follows.
enum DocsSection: String, CaseIterable {
    case textFiles = "configuration#open-files-in-your-terminal-editor"

    static let base = URL(string: "https://macterm.thdxg.dev/docs/")!

    var url: URL {
        URL(string: rawValue, relativeTo: Self.base)?.absoluteURL ?? Self.base
    }

    /// The page slug, e.g. `configuration`.
    var page: String {
        String(rawValue.prefix { $0 != "#" })
    }

    /// The heading anchor, e.g. `open-files-in-your-terminal-editor`.
    var anchor: String {
        rawValue.firstIndex(of: "#").map { String(rawValue[rawValue.index(after: $0)...]) } ?? ""
    }
}

/// The system's help button (`HelpLink`), opening `section` in the browser.
/// Goes in a Settings section's header, trailing, the way the Ghostty Config
/// section carries its add menu.
struct DocsLink: View {
    let section: DocsSection

    init(_ section: DocsSection) {
        self.section = section
    }

    var body: some View {
        HelpLink(destination: section.url)
            .controlSize(.small)
            .help("Open the docs for this section")
    }
}
