import Foundation
@testable import Macterm
import Testing

/// The skills `macterm skills` prints. Two halves: the Agent Skills format and
/// the catalog's shape, checked in process; and the bundled CLI itself, run
/// from the test host's bundle — it must print exactly this text, and every
/// `macterm …` command line in the text must parse against its own command
/// tree, so the skills can't drift from the CLI they describe.
struct AgentSkillsTests {
    // MARK: - Format

    @Test
    func names_are_valid_unique_and_their_folders() {
        let names = AgentSkills.all.map(\.name)
        #expect(Set(names).count == names.count, "duplicate skill names: \(names)")
        for skill in AgentSkills.all {
            #expect(skill.name.count <= 64, "\(skill.name) is longer than 64 characters")
            #expect(
                skill.name.range(of: "^[a-z0-9]+(-[a-z0-9]+)*$", options: .regularExpression) != nil,
                "\(skill.name) must be lowercase letters, digits and single inner hyphens"
            )
            #expect(skill.path == "\(skill.name)/SKILL.md")
            #expect(AgentSkills.named(skill.name) == skill)
        }
        #expect(AgentSkills.named("macterm") == nil)
    }

    @Test
    func descriptions_say_what_and_when_as_a_plain_yaml_scalar() {
        for skill in AgentSkills.all {
            let description = skill.description
            #expect(!description.isEmpty)
            #expect(description.count <= 1024, "\(skill.name): description is \(description.count) characters")
            #expect(description.contains("Use when"), "\(skill.name): the description must say when to use it")
            // Emitted unquoted, so it must parse as a YAML plain scalar: one
            // line, no `: ` or ` #`, no leading indicator, no edge whitespace.
            #expect(!description.contains("\n") && !description.contains("\t"))
            #expect(!description.contains(": ") && !description.contains(" #"), "\(skill.name): not a plain scalar")
            #expect(description.trimmingCharacters(in: .whitespaces) == description)
            #expect(!"-?:,[]{}#&*!|>'\"%@`".contains(description.first ?? " "))
        }
    }

    @Test
    func each_file_is_frontmatter_then_a_body_that_stands_alone() {
        for skill in AgentSkills.all {
            let text = skill.fileText
            let lines = text.components(separatedBy: "\n")
            #expect(Array(lines.prefix(5)) == [
                "---", "name: \(skill.name)", "description: \(skill.description)", "---", "",
            ])
            #expect(text.hasSuffix("\n") && !text.hasSuffix("\n\n"), "\(skill.name) must end with one newline")
            // The format's advice: an agent reads all of it once the skill
            // activates, so keep each one under 500 lines.
            #expect(lines.count < 500, "\(skill.name) is \(lines.count) lines")
            // Agents load one skill at a time, so each carries the shared rules
            // and its own staleness note.
            #expect(text.contains(AgentSkills.groundRules), "\(skill.name) is missing the ground rules")
            #expect(text.contains(AgentSkills.currencyNote(for: skill.name)))
            // Nothing inside a skill may look like the catalog's delimiter.
            #expect(!lines.contains { $0.hasPrefix("==> ") }, "\(skill.name) has a line that reads as a delimiter")
            // Code spans stay on one line (and so stay checkable, below).
            Self.forEachProseLine(of: skill) { line in
                #expect(line.count(where: { $0 == "`" }).isMultiple(of: 2), "\(skill.name): code span wraps: \(line)")
            }
        }
    }

    // MARK: - Catalog

    @Test
    func the_catalog_splits_back_into_the_skills_it_printed() {
        let lines = AgentSkills.catalogText.components(separatedBy: "\n")
        let delimiters = lines.indices.filter { lines[$0].hasPrefix("==> ") && lines[$0].hasSuffix(" <==") }
        #expect(delimiters.map { lines[$0] } == AgentSkills.all.map(AgentSkills.delimiter(for:)))
        #expect(lines[..<(delimiters.first ?? 0)].joined(separator: "\n") == AgentSkills.header)
        for (position, start) in delimiters.enumerated() {
            let end = position + 1 < delimiters.count ? delimiters[position + 1] : lines.count - 1
            let file = lines[(start + 1) ..< end].joined(separator: "\n") + "\n"
            #expect(file == AgentSkills.all[position].fileText, "\(AgentSkills.all[position].name) did not round-trip")
        }
    }

    @Test
    func the_list_names_every_skill_once() {
        let lines = AgentSkills.listText.split(separator: "\n").map(String.init)
        #expect(lines.count == AgentSkills.all.count)
        for (line, skill) in zip(lines, AgentSkills.all) {
            #expect(line.hasPrefix(skill.name + " ") && line.hasSuffix(skill.description))
        }
    }

    // MARK: - The bundled CLI

    @Test
    func the_bundled_cli_prints_exactly_this_text() throws {
        let all = try Self.cli(["skills"])
        #expect(all.status == 0)
        #expect(all.stdout == AgentSkills.catalogText)

        for skill in AgentSkills.all {
            let one = try Self.cli(["skills", skill.name])
            #expect(one.status == 0)
            #expect(one.stdout == skill.fileText, "`macterm skills \(skill.name)` is not the SKILL.md verbatim")
        }

        let list = try Self.cli(["skills", "--list"])
        #expect(list.status == 0)
        #expect(list.stdout == AgentSkills.listText)

        // stdout only on success; the error and its hint go to stderr.
        let unknown = try Self.cli(["skills", "no-such-skill"])
        #expect(unknown.status == 1)
        #expect(unknown.stdout.isEmpty)
        #expect(unknown.stderr.contains("--list"))
        let both = try Self.cli(["skills", "--list", AgentSkills.all[0].name])
        #expect(both.status == 1)
        #expect(both.stdout.isEmpty)
    }

    @Test
    func the_bundled_cli_prints_the_skills_as_json() throws {
        struct Payload: Decodable {
            struct Skill: Decodable {
                let name: String
                let description: String
                let path: String
                let text: String?
            }

            let skills: [Skill]
        }
        let full = try JSONDecoder().decode(Payload.self, from: Data(Self.cli(["skills", "--json"]).stdout.utf8))
        #expect(full.skills.map(\.name) == AgentSkills.all.map(\.name))
        #expect(full.skills.map(\.path) == AgentSkills.all.map(\.path))
        #expect(full.skills.map(\.text) == AgentSkills.all.map(\.fileText))

        let list = try JSONDecoder().decode(
            Payload.self, from: Data(Self.cli(["skills", "--list", "--json"]).stdout.utf8)
        )
        #expect(list.skills.map(\.description) == AgentSkills.all.map(\.description))
        #expect(list.skills.allSatisfy { $0.text == nil })
    }

    /// The copyable setup prompt in `macterm skills -h` is the feature's front
    /// door; losing it in a help-text edit would go unnoticed otherwise.
    @Test
    func the_help_carries_a_prompt_to_give_an_agent() throws {
        let help = try Self.cli(["skills", "--help"])
        #expect(help.status == 0)
        let flattened = help.stdout.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flattened.contains("Run `macterm skills`"))
        #expect(flattened.contains("into your skills directory as <name>/SKILL.md, exactly as printed."))
        #expect(flattened.contains("Then tell me what you installed and where."))
    }

    /// Every `macterm …` command line in a fenced block or code span, and every
    /// code span that starts with one of the CLI's nouns, must be a real
    /// subcommand given only options it declares, with no more arguments than
    /// it takes: parsed against the bundled CLI's own `--experimental-dump-help`
    /// tree, the same one `--help` renders. Debug-only verbs don't count as
    /// real, since a release CLI lacks them.
    @Test
    func every_command_in_the_skills_is_one_the_cli_accepts() throws {
        let dump = try Self.cli(["--experimental-dump-help"])
        #expect(dump.status == 0)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(dump.stdout.utf8)) as? [String: Any])
        let root = try CommandNode(json: #require(json["command"] as? [String: Any]))

        var checked = 0
        for skill in AgentSkills.all {
            for invocation in Self.invocations(in: skill, root: root) {
                checked += 1
                if let problem = root.problem(with: invocation) {
                    Issue.record("\(skill.name): `macterm \(invocation.joined(separator: " "))` — \(problem)")
                }
            }
        }
        // Guards the extraction itself: a parser that found nothing would pass.
        #expect(checked > 60, "only \(checked) command lines found in the skills")
    }

    // MARK: - Helpers

    private static func cli(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let binary = try #require(
            Bundle.main.url(forResource: "macterm", withExtension: nil, subdirectory: "bin"),
            "bin/macterm missing from the built bundle"
        )
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Drain both pipes before waiting, or a full pipe deadlocks the child.
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    /// Lines of a skill outside its fenced code blocks.
    private static func forEachProseLine(of skill: AgentSkill, _ body: (String) -> Void) {
        var fenced = false
        for line in skill.fileText.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fenced.toggle()
            } else if !fenced {
                body(line)
            }
        }
    }

    /// The command lines a skill shows, each as the words after `macterm`:
    /// every fenced line and code span, split like a shell would split it and
    /// cut at the first operator (a pipe, `;`, `&&`, a redirect, a
    /// parenthesis). A code span without the `macterm` prefix counts when its
    /// first word is one of the CLI's own subcommands (`pane key return`).
    private static func invocations(in skill: AgentSkill, root: CommandNode) -> [[String]] {
        var snippets: [(text: String, inline: Bool)] = []
        var fenced = false
        for line in skill.fileText.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fenced.toggle()
            } else if fenced {
                snippets.append((line, false))
            } else {
                let parts = line.components(separatedBy: "`")
                for index in stride(from: 1, to: parts.count, by: 2) {
                    snippets.append((parts[index], true))
                }
            }
        }
        var found: [[String]] = []
        for snippet in snippets {
            var words = shellWords(snippet.text)
            if snippet.inline, words.count > 1, root.subcommands[words[0]] != nil {
                words.insert("macterm", at: 0)
            }
            for (index, word) in words.enumerated() where (word as NSString).lastPathComponent == "macterm" {
                found.append(Array(words[(index + 1)...].prefix { !shellOperators.contains($0) }))
            }
        }
        return found
    }

    private static let shellOperators: Set<String> = ["|", ";", "&", "(", ")", "<", ">", "`"]

    /// Just enough of a shell's word splitting to find where an invocation
    /// ends: quotes and backslashes, with each operator as a word of its own.
    private static func shellWords(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        func finish() {
            if inWord { words.append(current) }
            current = ""
            inWord = false
        }
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"" {
                    escaped = true
                } else {
                    current.append(character)
                }
            } else if character == "\\" {
                escaped = true
                inWord = true
            } else if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character == " " || character == "\t" {
                finish()
            } else if shellOperators.contains(String(character)) {
                finish()
                words.append(String(character))
            } else if character == "#", !inWord {
                break
            } else {
                current.append(character)
                inWord = true
            }
        }
        finish()
        return words
    }
}

/// One command of the CLI's `--experimental-dump-help` tree.
private struct CommandNode {
    let abstract: String
    let subcommands: [String: CommandNode]
    /// Spelled as typed: `--session`, `-h`.
    let flags: Set<String>
    let valueOptions: Set<String>
    let positionals: Int
    let repeatsPositionals: Bool
    /// `pane run`'s text, `ssh`'s argv: past its first word nothing is parsed.
    let takesRemainingInput: Bool

    init(json: [String: Any]) {
        abstract = json["abstract"] as? String ?? ""
        var subcommands: [String: CommandNode] = [:]
        for child in json["subcommands"] as? [[String: Any]] ?? [] {
            if let name = child["commandName"] as? String {
                subcommands[name] = CommandNode(json: child)
            }
        }
        self.subcommands = subcommands
        var flags: Set<String> = []
        var valueOptions: Set<String> = []
        var positionals = 0
        var repeats = false
        var remaining = false
        for argument in json["arguments"] as? [[String: Any]] ?? [] {
            let spellings = (argument["names"] as? [[String: Any]] ?? []).compactMap { name -> String? in
                guard let text = name["name"] as? String else { return nil }
                return (name["kind"] as? String == "long" ? "--" : "-") + text
            }
            switch argument["kind"] as? String {
            case "flag": flags.formUnion(spellings)
            case "option": valueOptions.formUnion(spellings)
            default:
                positionals += 1
                repeats = repeats || argument["isRepeating"] as? Bool == true
                remaining = remaining || argument["parsingStrategy"] as? String == "allRemainingInput"
            }
        }
        self.flags = flags
        self.valueOptions = valueOptions
        self.positionals = positionals
        repeatsPositionals = repeats
        takesRemainingInput = remaining
    }

    /// Why `words` (what follows `macterm`) wouldn't parse, or nil if it would.
    func problem(with words: [String]) -> String? {
        var node = self
        var path: [String] = []
        var index = 0
        while index < words.count, let child = node.subcommands[words[index]] {
            node = child
            path.append(words[index])
            index += 1
        }
        if node.abstract.hasPrefix("[debug]") {
            return "`\(path.joined(separator: " "))` exists only in debug builds"
        }
        if path == ["help"] {
            var topic = self
            for word in words[index...] {
                guard let child = topic.subcommands[word] else { return "no `\(word)` subcommand to show help for" }
                topic = child
            }
            return nil
        }
        var arguments: [String] = []
        while index < words.count {
            let word = words[index]
            index += 1
            if word.hasPrefix("-"), word.count > 1 {
                let spelling = String(word.split(separator: "=", maxSplits: 1)[0])
                if node.flags.contains(spelling) { continue }
                guard node.valueOptions.contains(spelling) else {
                    return "`\(path.joined(separator: " "))` has no \(spelling) option"
                }
                if !word.contains("=") { index += 1 }
                continue
            }
            if node.takesRemainingInput { break }
            arguments.append(word)
        }
        if !node.repeatsPositionals, arguments.count > node.positionals {
            return "`\(path.joined(separator: " "))` takes \(node.positionals) argument(s), not \(arguments)"
        }
        if path == ["skills"], let unknown = arguments.first(where: { AgentSkills.named($0) == nil }) {
            return "there is no skill named \(unknown)"
        }
        return nil
    }
}
