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
        #expect(line.contains("${" + TextFileEditor.commandVariable + ":-"))
    }

    @Test
    func the_environment_carries_the_file_line_and_command() {
        let env = TextFileEditor.environment(path: "/a b/it's.swift", line: 42, command: "  hx ")
        #expect(env == [
            "MACTERM_EDITOR_FILE": "/a b/it's.swift",
            "MACTERM_EDITOR_LINE": "42",
            "MACTERM_EDITOR": "hx",
        ])
    }

    @Test
    func no_line_and_a_blank_command_leave_both_unset() {
        // Unset, not empty: the script falls back to the shell's $EDITOR.
        let env = TextFileEditor.environment(path: "/x.md", line: nil, command: "   ")
        #expect(env == ["MACTERM_EDITOR_FILE": "/x.md"])
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

        let withLine = TextFileEditor.environment(path: "/a b/it's $x.rs", line: 7, command: editor.path + " --wait")
        #expect(try run(withLine) == "[--wait][+7][/a b/it's $x.rs]")

        var fromEditorVariable = TextFileEditor.environment(path: "/x.md", line: nil, command: "")
        fromEditorVariable["EDITOR"] = editor.path
        #expect(try run(fromEditorVariable) == "[/x.md]")
    }
}
