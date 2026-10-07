import Foundation
@testable import Macterm
import Testing

struct TextFileEditorTests {
    @Test
    func the_typed_line_is_one_single_quoted_sh_script() {
        let line = TextFileEditor.typedCommand
        // Exactly two single quotes (the script's delimiters) and no
        // backslash: the only characters fish interprets inside single
        // quotes, and nu's raw strings have no escapes at all.
        #expect(line.count(where: { $0 == "'" }) == 2)
        #expect(!line.contains("\\"))
        #expect(!line.contains("\n"))
        // A leading space keeps it out of history where shells allow.
        #expect(line.hasPrefix(" exec sh -c '"))
        #expect(line.hasSuffix("'"))
    }

    @Test
    func the_script_reads_every_variable_the_environment_sets() {
        let line = TextFileEditor.typedCommand
        #expect(line.contains("$" + TextFileEditor.fileVariable))
        #expect(line.contains("$" + TextFileEditor.lineVariable))
        // The editor is the user's own, in the order git and less use.
        #expect(line.contains("${VISUAL:-${EDITOR:-vi}}"))
    }

    @Test
    func the_environment_carries_the_file_and_line() {
        let env = TextFileEditor.environment(path: "/a b/it's.swift", line: 42)
        #expect(env == [
            "MACTERM_EDITOR_FILE": "/a b/it's.swift",
            "MACTERM_EDITOR_LINE": "42",
        ])
    }

    @Test
    func no_line_leaves_the_line_unset() {
        // Unset, not empty: the script then passes no `+LINE` at all.
        #expect(TextFileEditor.environment(path: "/x.md", line: nil) == ["MACTERM_EDITOR_FILE": "/x.md"])
        #expect(TextFileEditor.environment(path: "/x.md", line: 0) == ["MACTERM_EDITOR_FILE": "/x.md"])
    }

    @Test
    func the_script_runs_the_editor_with_the_line_and_file() throws {
        // Run the real line through /bin/sh with a stand-in editor that
        // prints its arguments, so the script itself is exercised.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let editor = dir.appendingPathComponent("fake-editor")
        try "#!/bin/sh\nfor a in \"$@\"; do printf '[%s]' \"$a\"; done\n"
            .write(to: editor, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: editor.path)

        func run(_ env: [String: String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", TextFileEditor.typedCommand]
            process.environment = ["PATH": "/usr/bin:/bin"].merging(env) { $1 }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardInput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }

        // $EDITOR with arguments, a line, and a path no shell grammar likes.
        var withLine = TextFileEditor.environment(path: "/a b/it's $x.rs", line: 7)
        withLine["EDITOR"] = editor.path + " --wait"
        #expect(try run(withLine) == "[--wait][+7][/a b/it's $x.rs]")

        // $VISUAL wins over $EDITOR.
        var visual = TextFileEditor.environment(path: "/x.md", line: nil)
        visual["VISUAL"] = editor.path
        visual["EDITOR"] = "/nonexistent/editor"
        #expect(try run(visual) == "[/x.md]")
    }
}
