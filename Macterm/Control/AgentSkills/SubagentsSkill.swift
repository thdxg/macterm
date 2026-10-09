extension AgentSkills {
    /// Running other coding agents in their own tabs or panes: start one,
    /// prompt it, follow it, clean up after it.
    static let subagents = AgentSkill(
        name: "macterm-subagents",
        description: """
        Run other coding agents (Claude Code, Codex, Gemini CLI, OpenCode and the like) as sub-agents in their \
        own Macterm tabs or split panes with the macterm CLI. Start one with a command, wait for its input \
        prompt, type a task into it, follow its progress through pane list states and pane dump, answer its \
        questions, and close it when it is done. Use when asked to run work in parallel with sub-agents, to \
        hand a task to another agent in a terminal the user can watch, to check on or reply to an agent that \
        runs in a Macterm pane, or to clean up agents that you started.
        """,
        body: #"""
        # Sub-agents in Macterm panes

        An agent CLI that starts in its own tab or pane works where the user can watch it. It keeps running if
        Macterm quits, because its zmx session keeps running. You can drive it fully with the `macterm` CLI:
        `pane run` and `pane key` to type, `pane dump` to read the screen, `pane list` to follow its state.

        \#(groundRules)

        ## 1. Start it

        Use a background tab. The view and the focus of the user do not change:

        ```sh
        macterm project list --json
        macterm tab new --project api --no-focus --run "claude" --json
        macterm pane list --project api --tab 4 --json
        ```

        Choose a loaded project whose `path` holds the work. `--no-focus` starts the terminal also if that
        project is not on the screen. Without it, a tab in another project can wait until someone views it. If
        the app is too old for `--no-focus`, the command fails (exit 1) before it creates anything. It does not
        take the focus in silence. `tab new` uses the active project by default. It does not use the project
        of the caller, so pass `--project`. Its reply gives the `index` and the `id` of the new tab. With
        either one, `pane list --tab` gives the `session` of its pane. To start the agent next to you, split
        your own pane and do not take the focus. The reply is the new pane itself:

        ```sh
        macterm pane split --direction right --no-focus --run "codex" --json
        ```

        Outside Macterm, add `--session` with the name of the pane to split. Without it, you split the pane
        that the user has focused. Keep the session name. Every later command targets it with `--session`. It
        keeps working after Macterm restarts, and while the user looks at another project.

        ## 2. Wait for its prompt, then type the task

        An agent needs a few seconds to start. It can ask something first, for example if it can trust the
        folder. Read the screen until the input prompt of the agent shows:

        ```sh
        macterm pane dump --session macterm-api-2a6f7e69fb6e
        ```

        Poll it every second or two, with a deadline. Never type before the prompt is there. The keystrokes for
        the task would answer a startup question. If a startup question is on the screen, ask the user, unless
        the user already told you the answer. Then type the task and submit it:

        ```sh
        macterm pane run --session macterm-api-2a6f7e69fb6e --no-submit -- "Fix the failing test in parser_test.go."
        macterm pane key --session macterm-api-2a6f7e69fb6e return
        ```

        `--no-submit` leaves the text in the input box of the agent. `pane key return` presses a real Return,
        and an agent takes that as submit. A newline that you type can only add a line to the box. Read the
        dump again to see that the agent started to work.

        For a long prompt, or a prompt with several lines, write it to a file with your own tools. Then type
        one line: `Read /tmp/task-4f1c.md and do what it says.` This keeps quoting, length and line breaks out
        of the terminal. Also ask for a definite signal in the prompt. For example: "When you have finished,
        create the file /tmp/task-4f1c.done". Wait for that file.

        ## 3. Follow it

        ```sh
        macterm pane list --project api --json
        macterm pane dump --session macterm-api-2a6f7e69fb6e | tail -40
        ```

        Find the session of the agent in the list and read its `state`. `running` means that it produces
        output. About 3 seconds after its output stops, the state changes to `done`. If the user looks at that
        tab, it changes to `idle`. This means that the agent finished, or that it waits for you. It can wait for
        a question, a choice or a permission prompt. The dump shows which. Check every 10 to 30 seconds. Do not
        use a tight loop.

        Answer it in the same way as you prompted it. Use text with `--no-submit`, then `pane key return`. For
        a menu, use single keys (`pane key 1`, `pane key down`, `pane key return`, `pane key escape`). A
        permission prompt is the decision of the user, unless the user gave you that authority.
        `pane key ctrl+c` interrupts the agent.

        ## 4. Clean up

        When you close a pane, its session ends and its scrollback is gone. Copy what you still need from
        `pane dump --scrollback` first. Quit the agent with its own command (often `/exit` or `/quit`, if not,
        `ctrl+c`). Check that the pane is back at a shell prompt. Then close it:

        ```sh
        macterm pane run --session macterm-api-2a6f7e69fb6e --no-submit -- "/exit"
        macterm pane key --session macterm-api-2a6f7e69fb6e return
        macterm pane close --session macterm-api-2a6f7e69fb6e
        ```

        When you close the only pane of a tab, the tab closes. `macterm tab close --project api 4` closes a
        whole tab at once. Both commands answer `busy` while the agent, or anything else, still runs there.
        Ask the user before you run the command again with `--force`. That flag kills the agent in the middle
        of its work.

        \#(currencyNote(for: "macterm-subagents"))
        """#
    )
}
