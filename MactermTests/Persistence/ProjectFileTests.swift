import Foundation
@testable import Macterm
import Testing

struct ProjectFileTests {
    // MARK: - Decode

    @Test
    func folderless_layout_round_trips_with_its_project_id() throws {
        let file = ProjectFile(name: "Scratch", id: UUID(), path: nil, tabs: [LayoutTab(name: "Shell", layout: .pane(LayoutPane()))])
        let yaml = try file.yaml()
        #expect(!yaml.contains("path:"))
        #expect(try ProjectFile.parse(yaml: yaml) == file)
        #expect(ProjectFile.parseHeader(yaml: yaml)?.id == file.id)
        #expect(throws: LayoutFileError.self) { try ProjectFile.parse(yaml: "id: not-a-uuid") }
        #expect(throws: LayoutFileError.self) { try ProjectFile.parse(yaml: "id: \(PinnedTabs.projectID)") }
    }

    @Test
    func bare_declaration_without_tabs_decodes() throws {
        let file = try ProjectFile.parse(yaml: """
        name: API server
        path: ~/dev/api
        """)
        #expect(file.name == "API server")
        #expect(file.path == "~/dev/api")
        #expect(file.tabs == nil)
        #expect(file.layoutFile == nil)
    }

    @Test
    func empty_tabs_bridges_to_no_layout() throws {
        let file = try ProjectFile.parse(yaml: """
        path: /a/b
        tabs: []
        """)
        #expect(file.layoutFile == nil)
    }

    @Test
    func tabs_reuse_the_layout_schema() throws {
        let file = try ProjectFile.parse(yaml: """
        name: Proj
        path: /a/b
        tabs:
          - name: Dev
            split:
              direction: vertical
              ratio: 0.7
              first: { run: "npm run dev" }
              second: { }
        """)
        let layout = try #require(file.layoutFile)
        #expect(layout.name == "Proj")
        #expect(layout.tabs.count == 1)
        guard case let .split(branch) = layout.tabs[0].layout else {
            Issue.record("expected split")
            return
        }
        #expect(branch.direction == .vertical)
        #expect(branch.ratio == 0.7)
    }

    /// `id` was a key that decoding ignored before projects without a
    /// folder. A file with a folder that carries some other `id:` keeps
    /// reading, with its header too, so it still matches its project.
    @Test
    func an_id_that_is_not_a_uuid_does_not_break_a_file_with_a_path() throws {
        let yaml = """
        path: ~/dev/api
        id: api
        tabs:
          - {}
        """
        let file = try ProjectFile.parse(yaml: yaml)
        #expect(file.path == "~/dev/api")
        #expect(file.id == nil)
        #expect(file.identity == .path("~/dev/api"))
        let header = try #require(ProjectFile.parseHeader(yaml: yaml))
        #expect(header.path == "~/dev/api")
        #expect(header.id == nil)
    }

    /// The ID is the only identity of a project without a folder, so a saved
    /// file has it at the top, before `tabs:`, where a hand edit of the
    /// layout does not reach it.
    @Test
    func a_saved_file_writes_its_id_before_its_tabs() throws {
        let file = ProjectFile(
            name: "Scratch",
            id: UUID(),
            tabs: [LayoutTab(name: "Shell", layout: .pane(LayoutPane(cwd: nil, run: "btop", shell: nil)))]
        )
        let lines = try file.yaml().split(separator: "\n").map(String.init)
        let idLine = try #require(lines.firstIndex { $0.hasPrefix("id:") })
        let tabsLine = try #require(lines.firstIndex { $0.hasPrefix("tabs:") })
        #expect(idLine < tabsLine)
    }

    @Test
    func missing_path_fails_full_decode() {
        #expect(throws: LayoutFileError.self) {
            try ProjectFile.parse(yaml: "name: no path here")
        }
    }

    @Test
    func round_trips_through_yaml_with_modeline() throws {
        let original = ProjectFile(
            name: "API",
            path: "~/dev/api",
            tabs: [LayoutTab(name: "Dev", layout: .pane(LayoutPane(cwd: nil, run: "btop", shell: nil)))]
        )
        let text = try original.yaml()
        #expect(text.hasPrefix(ProjectFile.schemaModeline))
        #expect(try ProjectFile.parse(yaml: text) == original)
    }

    // MARK: - Header decode

    @Test
    func header_survives_tabs_schema_errors() {
        // `split` missing `second` fails the full decode but the header —
        // which never looks at tabs — still identifies the file.
        let yaml = """
        name: Broken
        path: /a/b
        tabs:
          - split: { direction: horizontal, first: { } }
        """
        #expect(throws: LayoutFileError.self) { try ProjectFile.parse(yaml: yaml) }
        let header = ProjectFile.parseHeader(yaml: yaml)
        #expect(header?.path == "/a/b")
        #expect(header?.name == "Broken")
    }

    @Test
    func header_fails_on_yaml_syntax_error() {
        #expect(ProjectFile.parseHeader(yaml: "path: [unclosed") == nil)
    }

    // MARK: - Slug

    @Test
    func slug_lowercases_and_underscores_whitespace() {
        #expect(ProjectSlug.slug(from: "API Server") == "api_server")
        #expect(ProjectSlug.slug(from: "  a  b ") == "__a__b_")
    }

    @Test
    func slug_keeps_unicode_letters_and_digits() {
        #expect(ProjectSlug.slug(from: "日本語プロジェクト") == "日本語プロジェクト")
        #expect(ProjectSlug.slug(from: "Café-2") == "café-2")
    }

    @Test
    func slug_strips_symbols_and_path_hostiles() {
        #expect(ProjectSlug.slug(from: "a/b:c*d") == "abcd")
        #expect(ProjectSlug.slug(from: "my.project!") == "myproject")
    }

    @Test
    func empty_slug_falls_back() {
        #expect(ProjectSlug.slug(from: "!!!") == "project")
        #expect(ProjectSlug.slug(from: "") == "project")
    }

    @Test
    func filename_suffixes_start_at_two() {
        #expect(ProjectSlug.filename(slug: "api", attempt: 1) == "api.yaml")
        #expect(ProjectSlug.filename(slug: "api", attempt: 2) == "api_2.yaml")
        #expect(ProjectSlug.filename(slug: "api", attempt: 3) == "api_3.yaml")
    }
}
