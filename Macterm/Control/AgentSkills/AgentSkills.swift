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
/// that persists, and running sub-agents in their own panes.
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
/// embeds `groundRules`, the CLI rules all three workflows depend on.
enum AgentSkills {
    static let all: [AgentSkill] = [panes, workspace, subagents]

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

    Skills for AI coding agents that use Macterm through its `macterm` CLI, in
    the Agent Skills format: one folder per skill, holding a SKILL.md. Install
    each skill below into your skills directory as <name>/SKILL.md, exactly as
    printed: its file is everything after its "==> <name>/SKILL.md <==" line, up
    to the next such line or the end of this output. Each skill stands alone.

    `macterm skills <name>` prints one skill by itself, ready to redirect into
    place, and `macterm skills --list` names them. The text comes from the CLI
    that printed it, so print and install them again after updating Macterm.
    They replace the single "macterm" skill from the Macterm Cookbook; remove
    that one if you installed it.

    """

    /// The rules every skill depends on, embedded in each one.
    static let groundRules = #"""
    ## Ground rules

    - **Reaching the CLI.** Inside a Macterm pane, `macterm` is on `PATH` and `$MACTERM_SESSION` names that
      pane, so a pane command with no target acts on the pane it runs in. Anywhere else, run
      `/Applications/Macterm.app/Contents/Resources/bin/macterm`; Macterm itself must be running.
    - **Targeting.** `--session <name>` is the stable address: session names come from `macterm pane list`,
      survive quitting and relaunching Macterm, and are found in whichever project holds them. `--pane pane:2`
      is the second pane of the active tab (add `--tab` for another tab) and shifts as splits change. An
      explicit target always beats the fallback, which is your own pane inside Macterm and the user's
      focused pane outside it.
    - **Flags before text.** In `pane run` and `pane key`, every flag goes before the text: everything after
      the text is typed into the pane, `--help` included. `macterm help pane run` shows help without typing.
    - **One argument.** `pane run` joins its arguments with spaces after your shell has removed their quotes,
      so pass the command line as one quoted string; quotes inside it then survive.
    - **The user's shell.** Typed text runs in the user's login shell, which may be nushell or fish. Wrap
      redirects, pipes, `&&`, variables and globs in `/bin/sh -c '…'`, or write a script file and type
      `/bin/sh /path/to/script.sh`.
    - **No terminal yet.** A pane in a tab that has never been on screen has no terminal: `pane run`, `key`,
      `dump` and `inspect` answer `no_surface`, and its `--run` command has not started. `macterm tab select`
      shows the tab (and switches what the user is looking at).
    - **Wait for a sentinel, never a fixed sleep.** Have the command create a file when it ends, or print a
      marker assembled at run time: `printf done-%s 4f1c` prints `done-4f1c`, which the echoed command line
      never contains. Use a fresh random token each time and give every wait loop a deadline.
    - **`busy` means ask.** Closing a pane, tab or project answers `busy` while a program runs there, and
      `layout apply` answers it whenever it would close any pane. Nothing has changed at that point: ask the
      user before retrying with `--force`, which closes them anyway and kills what they run.
    - **Results.** Exit 0 is success, 1 means Macterm refused (stderr says why), 2 means no Macterm is
      reachable, and 64 means the command line itself is malformed. stdout carries output only on success.
      Every command except `macterm ssh` accepts `--json`.
    """#

    /// The closing section of every skill: how to notice it has gone stale.
    static func currencyNote(for name: String) -> String {
        """
        ## Keeping this skill current

        This file came from `macterm skills \(name)`. If Macterm rejects a command shown here, the CLI has
        changed since: install the skill again from that command's output.
        """
    }
}
