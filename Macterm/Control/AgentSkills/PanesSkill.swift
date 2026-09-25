extension AgentSkills {
    /// Running commands in panes and reading what they show, interactive
    /// programs and TUIs included.
    static let panes = AgentSkill(
        name: "macterm-panes",
        description: """
        Run commands in Macterm terminal panes and read what they display, with the macterm CLI — type into \
        a pane with pane run, press keys with pane key, read the screen and scrollback with pane dump, check \
        the foreground process with pane inspect, and follow the idle, running and done states in pane list. \
        Use when asked to run something in a Macterm pane or tab, to look at what a Macterm terminal is \
        showing (an error, a log, a full-screen program), to wait for a command in a pane to finish, or to \
        drive an interactive program there (a REPL, debugger, pager, editor or installer) that a pipe can't reach.
        """,
        body: #"""
        # Running commands in Macterm panes

        `macterm pane dump` reads a terminal's own cells, so you can see what any pane shows, full-screen
        programs included, and `pane run` and `pane key` type into it. With those three you can work in a
        terminal you are not running in: run a command where the user can watch it, read the result, and drive
        programs that never write to a pipe.

        \#(groundRules)

        Type only into panes you created or the user pointed you at: keystrokes sent to a pane the user is
        typing in land in the middle of their work.

        ## Find the pane

        ```sh
        macterm pane list
        ```

        ```text
        tab:1  pane:1  *  macterm-api-8f327ce4a3f8  nu      ~/dev/api      idle
        tab:1  pane:2     macterm-api-1a2b3c4d5e6f  bash    ~/dev/api      running
        tab:2  pane:1     macterm-api-9be4cfc35119  Python  ~/dev/api/web  done
        ```

        The columns are the tab, the pane's number within that tab, `*` on the focused pane, the session name,
        the foreground process (the shell's own name at a prompt), the working directory and the state. It
        covers the active project: add `--project <name>` for another (`macterm project list` names them) or
        `--tab` for a single tab. `--json` adds each pane's `id` and its tab's `tabID`.

        The state:

        - `running`: Macterm sees work. A command started at the shell prompt counts until it exits; a
          full-screen program or a recognized agent CLI (claude, codex, gemini, opencode and others) counts
          while it keeps producing output.
        - `done`: it stopped while nobody was looking at that tab. Typing into the pane, or the user opening
          the tab, turns it back to `idle`; `pane dump` and `pane inspect` do not.
        - `idle`: at a prompt, or finished and already seen.

        Output-driven work settles about 3 seconds after the output stops, and a program Macterm doesn't
        recognize, such as a REPL computing silently, can read `idle` while it works. Treat the state as a
        cheap hint and confirm with a sentinel or `pane dump`.

        ## Run a command and wait for it

        ```sh
        macterm pane run --session macterm-api-8f327ce4a3f8 "/bin/sh -c 'make test; echo \$? > /tmp/make-4f1c.status'"
        for i in $(seq 1 600); do [ -e /tmp/make-4f1c.status ] && break; sleep 0.5; done
        cat /tmp/make-4f1c.status
        macterm pane dump --session macterm-api-8f327ce4a3f8 --scrollback | tail -40
        ```

        The output stays in the pane where the user can see it, and the status file receives the exit code:
        `\$?` keeps your own shell from expanding it, so the pane's `/bin/sh` does. `pane run` prints the
        pane's row when the text was delivered, which says nothing about the command itself.

        In a remote project the command runs on the remote host, so a local file never appears. Wait for a
        marker in the pane's text instead:

        ```sh
        macterm pane run --session macterm-api-8f327ce4a3f8 "/bin/sh -c 'make test; printf done-%s 7d2e; echo'"
        for i in $(seq 1 600); do
          macterm pane dump --session macterm-api-8f327ce4a3f8 --scrollback | grep -q done-7d2e && break
          sleep 1
        done
        ```

        Anything longer than a line, or with quotes of its own, belongs in a script file: write it with your own
        tools, then type `/bin/sh /tmp/job-4f1c.sh`.

        ## Read what a pane shows

        - `macterm pane dump --session …` prints the visible screen as text, prompt and echoed command lines
          included. `--scrollback` prints everything the pane still holds, oldest first; filter it with
          `tail` or `grep` rather than reading thousands of lines. If the user has scrolled the pane up, the
          visible screen is not the newest output, so search `--scrollback` for sentinels.
        - `macterm pane inspect --session …` reports the grid size, the scrollback counts, the foreground
          process id and command line (the shell itself when nothing else runs), and `needs confirm quit`,
          which is true while a program runs and is what makes closing that pane answer `busy`. Its
          `alt-screen` value is only a guess; it reads true at a fresh prompt.

        ## Drive an interactive program

        A REPL, debugger, pager, editor or installer reads keys, not a pipe. Start it, wait until `pane dump`
        shows it is ready, then send one step at a time and read the screen after each:

        ```sh
        macterm pane run --session macterm-api-8f327ce4a3f8 "python3 -q"
        for i in $(seq 1 40); do
          macterm pane dump --session macterm-api-8f327ce4a3f8 | grep -q '^>>>' && break
          sleep 0.5
        done
        macterm pane run --session macterm-api-8f327ce4a3f8 --no-submit "print(sum(range(10)))"
        macterm pane key --session macterm-api-8f327ce4a3f8 return
        macterm pane dump --session macterm-api-8f327ce4a3f8 | tail -2
        macterm pane key --session macterm-api-8f327ce4a3f8 ctrl+d
        ```

        - `pane run --no-submit` types text without pressing Return, and `pane key return` presses a real
          Return key. Use that pair for anything that isn't a shell prompt: plain `pane run` ends the text with
          a newline character, which shells and line-based REPLs take as Enter but a full-screen program may
          not.
        - `pane key` sends one key per call: `return`, `escape`, `tab`, `space`, `up`, `down`, `left`, `right`,
          a letter or digit, punctuation such as `;` or `/`, and chords such as `ctrl+c`, `ctrl+d`, `shift+a`
          (for `A`) or `shift+;` (for `:`). Letters are lowercase unless you add `shift+`. There are no tokens
          for backspace, delete, home, end or the function keys, so use the program's own bindings instead
          (`ctrl+u`, `ctrl+a`, `ctrl+e`, `ctrl+h`).
        - `pane key ctrl+c` interrupts whatever is running.

        A full-screen program redraws the whole screen, so plain `pane dump` is what it shows right now, and
        `--scrollback` adds nothing it drew. Editing a file in vim, for example:

        ```sh
        macterm pane run --session macterm-api-8f327ce4a3f8 "vim notes.txt"
        macterm pane key --session macterm-api-8f327ce4a3f8 i
        macterm pane run --session macterm-api-8f327ce4a3f8 --no-submit "a new first line"
        macterm pane key --session macterm-api-8f327ce4a3f8 escape
        macterm pane run --session macterm-api-8f327ce4a3f8 --no-submit ":wq"
        macterm pane key --session macterm-api-8f327ce4a3f8 return
        ```

        In a pager (`less`, `man`, `git log`), `pane key space` pages forward and `pane key q` quits.

        ## Showing the user

        `macterm pane focus --session …` selects the pane's tab, brings its window to the front and gives it the
        keyboard; `macterm tab select` switches tabs. Both change what the user is looking at, so use them when
        the user asked to see something, never just to read or type: every command above works on a pane in
        the background once its tab has been shown.

        \#(currencyNote(for: "macterm-panes"))
        """#
    )
}
