@testable import Macterm
import Testing

struct FileLinkTests {
    // MARK: - Parsing

    @Test
    func a_line_and_column_are_split_off_the_path() {
        #expect(FileLink.parse("src/app.ts:42:7") == FileLink(path: "src/app.ts", line: 42, column: 7))
        #expect(FileLink.parse("src/app.ts:42") == FileLink(path: "src/app.ts", line: 42))
        #expect(FileLink.parse("/abs/path/main.go:3") == FileLink(path: "/abs/path/main.go", line: 3))
    }

    @Test
    func a_path_without_a_position_is_still_a_link() {
        // Upstream may stop matching the suffix; a bare path must keep working.
        #expect(FileLink.parse("src/app.ts") == FileLink(path: "src/app.ts"))
        #expect(FileLink.parse("~/notes.md") == FileLink(path: "~/notes.md"))
    }

    @Test
    func a_name_without_a_slash_is_not_taken_for_a_url_scheme() {
        // `URL(string:)` reads `foo.swift:42` as scheme `foo.swift`.
        #expect(FileLink.parse("foo.swift:42") == FileLink(path: "foo.swift", line: 42))
    }

    @Test
    func urls_are_not_file_links() {
        #expect(FileLink.parse("https://example.com:8080") == nil)
        #expect(FileLink.parse("http://localhost:3000/path") == nil)
        #expect(FileLink.parse("file:///Users/me/a.txt") == nil)
        #expect(FileLink.parse("mailto:me@example.com") == nil)
        #expect(FileLink.parse("ssh://host:22") == nil)
    }

    @Test
    func only_the_trailing_position_is_taken() {
        // Colons inside the path stay in it; only `:N[:M]` at the end is a position.
        #expect(FileLink.parse("a:b/c.txt:12") == nil) // reads as a scheme `a:`
        #expect(FileLink.parse("dir/a:b.txt:12") == FileLink(path: "dir/a:b.txt", line: 12))
        #expect(FileLink.parse("dir/x.txt:1:2:3") == FileLink(path: "dir/x.txt:1", line: 2, column: 3))
    }

    @Test
    func a_zero_line_is_no_line() {
        #expect(FileLink.parse("dir/x.txt:0") == FileLink(path: "dir/x.txt"))
    }

    @Test
    func empty_and_position_only_text_is_nothing() {
        #expect(FileLink.parse("") == nil)
        #expect(FileLink.parse(":42") == nil)
    }

    // MARK: - Resolution

    @Test
    func a_relative_path_resolves_against_the_pane_directory() {
        let link = FileLink(path: "src/../lib/x.rs", line: 3)
        #expect(link.resolved(against: "/proj") == FileLink(path: "/proj/lib/x.rs", line: 3))
    }

    @Test
    func an_absolute_path_ignores_the_directory() {
        #expect(FileLink(path: "/etc/hosts").resolved(against: "/proj").path == "/etc/hosts")
    }

    @Test
    func a_tilde_path_expands_to_home() {
        let resolved = FileLink(path: "~/notes.md").resolved(against: "/proj").path
        #expect(resolved.hasPrefix("/"))
        #expect(resolved.hasSuffix("/notes.md"))
        #expect(!resolved.contains("~"))
    }

    @Test
    func a_relative_path_with_no_directory_stays_relative() {
        #expect(FileLink(path: "src/x.rs").resolved(against: nil).path == "src/x.rs")
    }
}
