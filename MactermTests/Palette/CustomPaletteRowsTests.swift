import Foundation
@testable import Macterm
import Testing

/// A listing command's output becoming rows (`CustomPaletteRows`).
struct CustomPaletteRowsTests {
    private func listing(
        rows: String? = nil,
        title: String = ".",
        subtitle: String? = nil,
        match: [String]? = nil,
        exports: [String: String] = [:],
        outcome: CustomPaletteOutcome = .enter(node: "next")
    ) -> CustomPalette.Listing {
        CustomPalette.Listing(
            command: "true",
            rowsPath: rows,
            title: title,
            subtitle: subtitle,
            icon: nil,
            match: match ?? [title, subtitle].compactMap(\.self),
            exports: exports,
            outcome: outcome
        )
    }

    @Test
    func a_json_object_with_rows_at_a_path_resolves_fields_exports_and_search_terms() throws {
        let output = """
        {"items": [
          {"metadata": {"name": "api", "namespace": "prod", "labels": {"app": "backend"}},
           "status": {"phase": "Running", "restarts": 3, "ready": true}},
          {"metadata": {"name": "web", "namespace": "prod", "labels": {}}, "status": {"phase": "Pending", "restarts": 0, "ready": false}}
        ]}
        """
        let rows = try CustomPaletteRows.parse(output: output, listing: listing(
            rows: ".items",
            title: ".metadata.name",
            subtitle: ".status.phase",
            match: [".metadata.name", ".metadata.namespace", ".metadata.labels.app", ".status.restarts", ".status.ready"],
            exports: ["POD": ".metadata.name", "NAMESPACE": ".metadata.namespace", "KIND": "pod"]
        ))
        #expect(rows.map(\.title) == ["api", "web"])
        #expect(rows.map(\.subtitle) == ["Running", "Pending"])
        #expect(rows[0].match == ["api", "prod", "backend", "3", "true"], "numbers and booleans read as text")
        #expect(rows[1].match == ["web", "prod", "0", "false"], "a missing field is skipped, not an empty term")
        #expect(rows[0].exports == ["POD": "api", "NAMESPACE": "prod", "KIND": "pod"], "a literal export is literal")
    }

    @Test
    func a_json_array_and_newline_delimited_objects_are_rows_too() throws {
        let array = try CustomPaletteRows.parse(output: #"[{"n": "a"}, {"n": "b"}]"#, listing: listing(title: ".n"))
        #expect(array.map(\.title) == ["a", "b"])
        let ndjson = try CustomPaletteRows.parse(output: "{\"n\": \"a\"}\n{\"n\": \"b\"}\n", listing: listing(title: ".n"))
        #expect(ndjson.map(\.title) == ["a", "b"])
        let scalars = try CustomPaletteRows.parse(output: #"["x", "y"]"#, listing: listing())
        #expect(scalars.map(\.title) == ["x", "y"], ". is the row itself")
    }

    @Test
    func plain_lines_are_rows_and_the_dot_is_the_line() throws {
        let rows = try CustomPaletteRows.parse(output: "main\n  feature/login \n\nold\n", listing: listing(exports: ["BRANCH": "."]))
        #expect(rows.map(\.title) == ["main", "feature/login", "old"])
        #expect(rows[1].exports == ["BRANCH": "feature/login"])
        #expect(try CustomPaletteRows.parse(output: "   \n", listing: listing()).isEmpty)
    }

    @Test
    func copy_and_open_operands_resolve_against_the_row() throws {
        let rows = try CustomPaletteRows.parse(
            output: #"[{"name": "docs", "url": "https://example.com/docs"}]"#,
            listing: listing(title: ".name", outcome: .perform(.open(".url")))
        )
        #expect(rows[0].operand == "https://example.com/docs")
        let literal = try CustomPaletteRows.parse(
            output: #"[{"name": "docs"}]"#,
            listing: listing(title: ".name", outcome: .perform(.copy("fixed text")))
        )
        #expect(literal[0].operand == "fixed text")
        let run = try CustomPaletteRows.parse(
            output: #"[{"name": "docs"}]"#,
            listing: listing(title: ".name", outcome: .perform(.run(command: "x", in: .tab)))
        )
        #expect(run[0].operand == nil)
    }

    @Test
    func a_row_without_a_title_is_dropped() throws {
        let rows = try CustomPaletteRows.parse(output: #"[{"n": "a"}, {"other": 1}, {"n": ""}]"#, listing: listing(title: ".n"))
        #expect(rows.map(\.title) == ["a"])
    }

    @Test
    func paths_take_indexes_and_leave_the_tree_quietly() {
        let tree: Any = ["items": [["name": "first", "tags": ["x", "y"]], ["name": "second"]], "count": 2]
        #expect(CustomPaletteRows.value(at: ".items[0].name", in: tree) as? String == "first")
        #expect(CustomPaletteRows.value(at: ".items[0].tags[1]", in: tree) as? String == "y")
        #expect(CustomPaletteRows.value(at: ".items[1].tags[0]", in: tree) == nil)
        #expect(CustomPaletteRows.value(at: ".items[9]", in: tree) == nil)
        #expect(CustomPaletteRows.value(at: ".count.deeper", in: tree) == nil)
        #expect(CustomPaletteRows.value(at: ".", in: "line") as? String == "line")
        #expect(CustomPaletteRows.resolve("literal", in: tree) == "literal")
        #expect(CustomPaletteRows.scalarText(["a": 1]) == nil, "objects don't read as text")
    }

    /// Output that only starts with a bracket — a log prefix — is lines,
    /// unless `rows:` asks for JSON or it opens a pretty-printed document.
    @Test
    func bracketed_plain_text_is_lines_and_pretty_json_still_fails() throws {
        let plain = try CustomPaletteRows.parse(output: "[INFO] main\n[WARN] dev\n", listing: listing())
        #expect(plain.map(\.title) == ["[INFO] main", "[WARN] dev"])
        #expect(throws: CustomPaletteRows.Failure.self) {
            try CustomPaletteRows.parse(output: "{\n  \"a\": 1\n}\n{\n  \"a\": 2\n}", listing: listing(title: ".a"))
        }
        #expect(throws: CustomPaletteRows.Failure.self, "truncated JSON isn't lines") {
            try CustomPaletteRows.parse(output: #"[{"a": 1}, {"a""#, listing: listing(title: ".a"))
        }
        #expect(throws: CustomPaletteRows.Failure.self) {
            try CustomPaletteRows.parse(output: "[INFO] main", listing: listing(rows: ".items"))
        }
    }

    /// Windows line ends, blank lines and non-string leaves.
    @Test
    func line_ends_blank_lines_and_scalar_leaves_read_as_text() throws {
        let lines = try CustomPaletteRows.parse(output: "one\r\n\r\ntwo\r\n", listing: listing())
        #expect(lines.map(\.title) == ["one", "two"])
        let rows = try CustomPaletteRows.parse(
            output: #"[{"n": 3, "ok": true, "f": 1.5, "none": null}]"#,
            listing: listing(title: ".n", subtitle: ".ok", exports: ["F": ".f", "NONE": ".none"])
        )
        #expect(rows.first?.title == "3")
        #expect(rows.first?.subtitle == "true")
        #expect(rows.first?.exports["F"] == "1.5")
        #expect(rows.first?.exports["NONE"] == nil, "a null leaves the variable unset")
    }

    @Test
    func the_failures_name_what_went_wrong() {
        #expect(throws: CustomPaletteRows.Failure.rowsNotFound(path: ".items")) {
            try CustomPaletteRows.parse(output: #"{"things": []}"#, listing: listing(rows: ".items"))
        }
        #expect(throws: CustomPaletteRows.Failure.rowsNotAnArray(path: ".items")) {
            try CustomPaletteRows.parse(output: #"{"items": {"a": 1}}"#, listing: listing(rows: ".items"))
        }
        #expect(throws: CustomPaletteRows.Failure.plainOutputWithRowsPath(path: ".items")) {
            try CustomPaletteRows.parse(output: "error: You must be logged in", listing: listing(rows: ".items"))
        }
        do {
            _ = try CustomPaletteRows.parse(output: "{not json", listing: listing())
            Issue.record("parsed")
        } catch CustomPaletteRows.Failure.notJSON {
            // Named: the palette shows "Output isn't JSON: …".
        } catch {
            Issue.record("wrong failure \(error)")
        }
    }
}
