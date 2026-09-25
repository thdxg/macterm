extension AgentSkills {
    /// Running other coding agents in their own tabs or panes: start one,
    /// prompt it, follow it, clean up after it.
    static let subagents = AgentSkill(
        name: "macterm-subagents",
        description: """
        Run other coding agents (Claude Code, Codex, Gemini CLI, OpenCode and the like) as sub-agents in their \
        own Macterm tabs or split panes with the macterm CLI — start one with a command, wait for its input \
        prompt, type a task into it, follow its progress through pane list states and pane dump, answer its \
        questions, and close it when it is done. Use when asked to run work in parallel with sub-agents, to \
        hand a task to another agent in a terminal the user can watch, to check on or reply to an agent running \
        in a Macterm pane, or to clean up agents you started.
        """,
        body: #"""
        # Sub-agents in Macterm panes

        An agent CLI started in its own tab or pane works where the user can watch it, keeps running if Macterm
        quits (its zmx session survives), and can be driven entirely through the `macterm` CLI: `pane run` and
        `pane key` to type, `pane dump` to read the screen, `pane list` to follow its state.

        \#(groundRules)

        ## 1. Start it

        In a new tab, which becomes the active tab, so the user's view switches to it:

        ```sh
        macterm project list --json
        macterm tab new --project api --run "claude" --json
        macterm pane list --project api --tab 4 --json
        ```

        Choose the project whose `path` holds the work, and make sure it is the one on screen (`active` in that
        list): a tab opened in another project gets no terminal until the user opens that project, so its agent
        doesn't start until then. `tab new` reports the new tab's `index` and `id`, and `pane list --tab` with either one
        gives its pane's `session`. To start the agent beside you instead, split your own pane; the reply is
        the new pane itself:

        ```sh
        macterm pane split --direction right --run "codex" --json
        ```

        Outside Macterm, add `--session` naming the pane to split, or you split whichever pane the user has
        focused. Keep the session name: every later command targets it with `--session`, which keeps working
        after Macterm restarts and while the user looks at another project.

        ## 2. Wait for its prompt, then type the task

        Agents take a few seconds to start and may ask something first, such as whether to trust the folder.
        Read the screen until the agent's input prompt is showing:

        ```sh
        macterm pane dump --session macterm-api-2a6f7e69fb6e
        ```

        Poll it every second or two, with a deadline. Never type before the prompt is there: keystrokes meant
        for the task would answer a startup question instead. If a startup question is on screen, ask the user
        unless they already told you the answer. Then type the task and submit it:

        ```sh
        macterm pane run --session macterm-api-2a6f7e69fb6e --no-submit "Fix the failing test in parser_test.go."
        macterm pane key --session macterm-api-2a6f7e69fb6e return
        ```

        `--no-submit` leaves the text in the agent's input box, and `pane key return` presses a real Return,
        which is what an agent takes as submit; a typed newline may only add a line to the box. Read the dump
        once more to see that the agent started working.

        For a long or multi-line prompt, write it to a file with your own tools and type one line instead:
        `Read /tmp/task-4f1c.md and do what it says.` That keeps quoting, length and line breaks out of the
        terminal. Ask for a definite signal in the prompt too, such as "When you have finished, create the
        file /tmp/task-4f1c.done", and wait for that file.

        ## 3. Follow it

        ```sh
        macterm pane list --project api --json
        macterm pane dump --session macterm-api-2a6f7e69fb6e | tail -40
        ```

        Find the agent's session in the list and read its `state`. `running` means it is producing output. It
        settles to `done` (or to `idle`, if the user is looking at that tab) about 3 seconds after its output
        stops, which means it either finished or is waiting for you: a question, a choice, a permission prompt.
        The dump says which. Check every 10 to 30 seconds rather than in a tight loop.

        Answer it the same way you prompted it: text with `--no-submit` followed by `pane key return`, or single
        keys for a menu (`pane key 1`, `pane key down`, `pane key return`, `pane key escape`). A permission
        prompt is the user's decision unless they gave you that authority. `pane key ctrl+c` interrupts it.

        ## 4. Clean up

        Closing a pane ends its session and throws away its scrollback, so copy anything you still need from
        `pane dump --scrollback` first. Quit the agent with its own command (often `/exit` or `/quit`, else
        `ctrl+c`), check that the pane is back at a shell prompt, then close it:

        ```sh
        macterm pane run --session macterm-api-2a6f7e69fb6e --no-submit "/exit"
        macterm pane key --session macterm-api-2a6f7e69fb6e return
        macterm pane close --session macterm-api-2a6f7e69fb6e
        ```

        Closing a tab's only pane closes the tab; `macterm tab close --project api 4` closes a whole tab at
        once. Both answer `busy` while the agent, or anything else, still runs there: ask the user before
        re-running with `--force`, which kills it mid-work.

        \#(currencyNote(for: "macterm-subagents"))
        """#
    )
}
