import SwiftUI

/// A part of the website's docs that a Settings section points to. Settings
/// keeps a one-line description for someone meeting the setting for the first
/// time; the docs carry the rest — formats, edge cases, how it interacts with
/// other settings — for whoever wants it.
///
/// The raw value is the page slug, plus the heading's anchor when the section
/// maps to one heading rather than a whole page. `website/build-docs.mjs`
/// derives an anchor from the heading text (lowercased, words joined by
/// hyphens), so renaming a heading moves it; `DocsLinkTests` reads the pages
/// back and fails until the case follows.
enum DocsSection: String, CaseIterable {
    case ghosttyConfig = "configuration"
    case textFiles = "configuration#open-files-in-your-terminal-editor"
    case remoteProjects = "remote-projects"
    case animations = "configuration#animations"
    case quickTerminal = "quick-terminal"
    case quickTerminalGeometry = "quick-terminal#position-and-size"
    case keybinds = "configuration#keybinds"
    case layouts = "declarative-layouts"
    case desktopWidgets = "desktop-widgets"
    case passwords
    case savedPasswords = "passwords#settings-password-manager"
    case palettes = "command-palette#settings-palettes"
    case customPalettes = "custom-palettes"

    static let base = URL(string: "https://macterm.thdxg.dev/docs/")!

    var url: URL {
        URL(string: rawValue, relativeTo: Self.base)?.absoluteURL ?? Self.base
    }

    /// The page slug, e.g. `configuration`.
    var page: String {
        String(rawValue.prefix { $0 != "#" })
    }

    /// The heading anchor, e.g. `open-files-in-your-terminal-editor`; nil for
    /// a whole page.
    var anchor: String? {
        rawValue.firstIndex(of: "#").map { String(rawValue[rawValue.index(after: $0)...]) }
    }
}

/// The system's help button (`HelpLink`), opening `section` in the browser.
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

/// A Settings section header with the docs button trailing — after any
/// controls the section already carries there, like an add menu.
struct DocsSectionHeader<Accessory: View>: View {
    let title: String
    let docs: DocsSection
    let accessory: Accessory

    init(_ title: String, docs: DocsSection, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.docs = docs
        self.accessory = accessory()
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            accessory
            DocsLink(docs)
        }
    }
}

extension DocsSectionHeader where Accessory == EmptyView {
    init(_ title: String, docs: DocsSection) {
        self.init(title, docs: docs) { EmptyView() }
    }
}
