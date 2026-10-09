import Foundation

/// One Agent Skill: a SKILL.md that a coding agent (Claude Code, Codex,
/// OpenCode, Gemini CLI, Cursor, …) loads from a skills directory, as
/// `<name>/SKILL.md`, and reads when a task matches its description.
struct AgentSkill: Equatable {
    /// Lowercase letters, digits and single hyphens, at most 64 characters —
    /// and the folder the skill installs into, which the format requires to
    /// match.
    let name: String
    /// What the skill does AND when to use it, on one line of at most 1024
    /// characters: agents decide from this alone whether to load the rest.
    /// Emitted as a plain YAML scalar, so it must never contain `: ` or ` #`.
    let description: String
    /// The markdown after the frontmatter, without a trailing newline.
    let body: String

    /// Where the skill installs, relative to a skills directory.
    var path: String { "\(name)/SKILL.md" }

    /// The complete SKILL.md — exactly what `macterm skills <name>` prints.
    var fileText: String {
        "---\nname: \(name)\ndescription: \(description)\n---\n\n\(body)\n"
    }
}

/// The skills `macterm skills` prints, teaching coding agents to drive Macterm
/// through the `macterm` CLI: running commands in panes, building a workspace
/// that persists, running sub-agents in their own panes, and writing custom
/// palette files.
///
/// Compiled into BOTH the app and the `MactermCLI` tool target (the
/// `ControlProtocol` / `SSHWrapper` pattern). The CLI prints the text offline,
/// so it always describes the CLI that printed it; the app module is where
/// `AgentSkillsTests` reaches it, including the drift test that runs every
/// `macterm …` command line in the text against the bundled CLI's own
/// command tree. Keep this free of app-only dependencies.
///
/// There is deliberately no installer: each agent knows where its own skills
/// live, so the output is shaped for the agent to install from — one skill
/// verbatim for redirecting into place, or all of them behind `header`, each
/// after a `delimiter` line naming its path.
///
/// Agents load one skill at a time, so every skill must stand alone: each
/// embeds `groundRules`, the CLI rules every workflow depends on.
enum AgentSkills {
    static let all: [AgentSkill] = [panes, workspace, subagents, palettes]

    static func named(_ name: String) -> AgentSkill? {
        all.first { $0.name == name }
    }

    /// The line that introduces each skill in `catalogText`.
    static func delimiter(for skill: AgentSkill) -> String {
        "==> \(skill.path) <=="
    }

    /// `macterm skills`: how to install them, then every skill in full.
    static var catalogText: String {
        all.reduce(header + "\n") { text, skill in
            text + delimiter(for: skill) + "\n" + skill.fileText
        }
    }

    /// `macterm skills --list`: one skill per line, name then description.
    static var listText: String {
        let width = all.map(\.name.count).max() ?? 0
        return all.map { skill in
            skill.name.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + skill.description + "\n"
        }.joined()
    }

    static let header = """
    Macterm agent skills

    Skills for AI coding agents that use Macterm through its `macterm` CLI. They
    use the Agent Skills format: one folder for each skill, with a SKILL.md file
    in it. Install each skill below into your skills directory as
    <name>/SKILL.md, exactly as printed. The file of a skill is everything after
    its "==> <name>/SKILL.md <==" line. It ends at the next such line, or at the
    end of this output. Each skill stands alone.

    `macterm skills <name>` prints one skill by itself, ready to redirect into
    place. `macterm skills --list` shows the names. The text comes from the CLI
    that printed it. Print and install the skills again after you update
    Macterm. They replace the single "macterm" skill from the Macterm Cookbook.
    If you installed that skill, remove it.

    """

    /// The rules every skill depends on, embedded in each one.
    static let groundRules = #"""
    ## Ground rules

    - **Reaching the CLI.** Inside a Macterm pane, `macterm` is in `PATH`, and `$MACTERM_SESSION` names that
      pane. A pane command with no target acts on the pane that it runs in. In any other place, run
      `/Applications/Macterm.app/Contents/Resources/bin/macterm`. Macterm must be running.
    - **Targeting.** `--session <name>` is the stable address. Session names come from `macterm pane list`.
      They stay the same after the user quits and starts Macterm again. The CLI finds a session in the project
      that holds it. `--pane pane:2` is the second pane of the active tab (add `--tab` for another tab). It
      changes when splits change. An explicit target always wins over the fallback. Inside Macterm, the
      fallback is your own pane. Outside Macterm, it is the focused pane of the user.
    - **Text after `--`.** In `pane run`, put the text after `--`. Macterm types it exactly as you wrote it:
      `macterm pane run --session macterm-api-8f327ce4a3f8 -- "ls -la"`. Before `--`, `pane run` reads its own
      flags at any place. It refuses a word that starts with `-` and types nothing.
    - **One argument.** `pane run` joins its arguments with spaces after your shell removes their quotes.
      Pass the command line as one quoted string. The quotes inside it then stay.
    - **The user's shell.** Macterm types the text into the login shell of the user. This can be nushell or
      fish. Put redirects, pipes, `&&`, variables and globs in `/bin/sh -c '…'`. Or write a script file and
      type `/bin/sh /path/to/script.sh`.
    - **No terminal yet.** A pane in a tab that was never on the screen has no terminal. `pane run`, `key`,
      `dump` and `inspect` answer `no_surface`, and its `--run` command did not start. `macterm tab select`
      shows the tab. It also changes what the user sees.
    - **Wait for a sentinel, not for a fixed time.** Make the command create a file when it ends, or print a
      marker that you assemble at run time: `printf done-%s 4f1c` prints `done-4f1c`. The echoed command line
      never contains it. Use a new random token each time. Give each wait loop a deadline.
    - **`busy` means ask.** Closing a pane, a tab or a project answers `busy` while a program runs there.
      `layout apply` answers `busy` each time that it would close a pane. Nothing changed at that point. Ask
      the user before you try again with `--force`. That flag closes them anyway and kills the programs that
      run in them.
    - **Results.** Exit 0 is success. Exit 1 means that Macterm refused the command (stderr says why). Exit 2
      means that no Macterm is reachable. Exit 64 means that the command line is malformed. stdout has output
      only on success. Every command except `macterm ssh` accepts `--json`.
    """#

    /// The closing section of every skill: how to notice it has gone stale.
    static func currencyNote(for name: String) -> String {
        """
        ## Keeping this skill current

        This file came from `macterm skills \(name)`. If Macterm rejects a command shown here, the CLI changed
        after you installed the skill. Install the skill again from the output of that command.
        """
    }
}
