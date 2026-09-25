import ArgumentParser
import Foundation

/// `macterm skills [name]` — print the Agent Skills (`AgentSkills`) that teach
/// coding agents to use Macterm through this CLI. Offline like `macterm ssh`:
/// the text is compiled in, so it needs no socket or running app, and it
/// always describes the CLI that printed it.
///
/// Deliberately no installer: every agent knows where its own skills live,
/// and we'd otherwise have to track each harness's layout. The output is
/// shaped for the agent to install from instead — every skill behind a header
/// saying how, or one skill verbatim so that
/// `macterm skills <name> > <dir>/<name>/SKILL.md` is the whole install.
struct SkillsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skills",
        abstract: "Print skills that teach AI coding agents to use Macterm (works without the app).",
        discussion: """
        Prints Agent Skills: SKILL.md files that Claude Code, Codex, OpenCode, Gemini CLI, Cursor and other \
        agents load from a skills directory. They teach an agent to run commands in panes and read their \
        output, to build a workspace that persists, and to run sub-agents in panes of their own. There is \
        no installer; the agent installs them itself. To set one up, give it this prompt:

          Run `macterm skills` and install each skill it prints into your skills
          directory as <name>/SKILL.md, exactly as printed. Then tell me what you
          installed and where. (Outside a Macterm pane, `macterm` is
          /Applications/Macterm.app/Contents/Resources/bin/macterm.)

        With no arguments, prints every skill after a short header on installing them, each introduced by \
        a line naming its path (==> <name>/SKILL.md <==). With a name, prints only that SKILL.md, verbatim, \
        ready to redirect into place.
        """
    )

    @Argument(help: "Print only this skill's SKILL.md, verbatim.")
    var name: String?

    @Flag(help: "List the skills' names and descriptions instead.")
    var list = false

    @Flag(help: "Print JSON: each skill's name, description, path and (without --list) text.")
    var json = false

    func run() throws {
        if list, name != nil {
            Output.printError("pass a skill name or --list, not both")
            throw ExitCode(1)
        }
        var skills = AgentSkills.all
        if let name {
            guard let skill = AgentSkills.named(name) else {
                Output.printError(
                    "no skill named \"\(name)\"",
                    action: "run `macterm skills --list` for their names"
                )
                throw ExitCode(1)
            }
            skills = [skill]
        }
        if json {
            try printJSON(skills)
        } else if list {
            print(AgentSkills.listText, terminator: "")
        } else if let skill = skills.first, name != nil {
            print(skill.fileText, terminator: "")
        } else {
            print(AgentSkills.catalogText, terminator: "")
        }
    }

    private struct Payload: Encodable {
        struct Skill: Encodable {
            let name: String
            let description: String
            let path: String
            let text: String?
        }

        let skills: [Skill]
    }

    private func printJSON(_ skills: [AgentSkill]) throws {
        let payload = Payload(skills: skills.map { skill in
            Payload.Skill(
                name: skill.name,
                description: skill.description,
                path: skill.path,
                text: list ? nil : skill.fileText
            )
        })
        // Same shape of output as every other verb's `--json` (see `Output`).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try print(String(decoding: encoder.encode(payload), as: UTF8.self))
    }
}
