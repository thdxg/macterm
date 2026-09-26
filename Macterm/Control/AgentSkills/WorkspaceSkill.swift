extension AgentSkills {
    /// Building a workspace — project, tabs, splits, grids — and making it
    /// last: the layout file, what survives a quit or a reboot, windows, and
    /// remote projects.
    static let workspace = AgentSkill(
        name: "macterm-workspace",
        description: """
        Build a Macterm workspace and make it persist, with the macterm CLI — find or create the project for a \
        directory, open tabs that run commands, split panes and grids, name tabs, then save the layout to its \
        YAML file in ~/.config/macterm/projects and apply it again later. Also explains what survives quitting \
        Macterm or rebooting, and covers windows and remote (ssh) projects. Use when asked to set up, arrange, \
        save or restore a Macterm project, tab or pane layout, to make a dev environment come back with its \
        commands running, or to add a local directory or a remote host as a Macterm project.
        """,
        body: #"""
        # Building a Macterm workspace

        A project is a directory, or a directory on a remote host, and appears as a section of Macterm's
        sidebar. It holds tabs; each tab is a tree of split panes; each pane is a shell running in a persistent
        zmx session. A window shows one project at a time.

        \#(groundRules)

        ## 1. Find the project, or create it once

        `project create` is not idempotent: every call adds another project, even for the same directory. Look
        before creating:

        ```sh
        macterm project list --json
        ```

        Each project has an `id`, a `name` and a `path`. If one already has your directory, select it;
        otherwise create it, once:

        ```sh
        macterm project select api
        macterm project create ~/dev/api --name api --select
        ```

        `--select` makes the new project the active one, which is the project the user is looking at. Name
        projects by `name` or `id` in later commands (`--project api`); two projects with the same name answer
        `ambiguous`, so pass the `id` then. `macterm project remove <id>` undoes a duplicate: it deletes no
        files, but it does kill that project's sessions.

        ## 2. Open tabs, split panes

        `tab new` opens a tab in the active project unless you pass `--project`, makes it that project's active
        tab (so the user's view switches to it), and `--run` types a command into its fresh shell:

        ```sh
        macterm tab new --project api --run "npm run dev" --json
        ```

        The reply's `tabs[0]` has the new tab's `index` and `id`. Split that tab by naming it, because inside a
        pane a split with no target splits the pane you are in:

        ```sh
        macterm pane split --project api --tab 2 --direction down --run "npm test -- --watch" --json
        macterm tab rename --project api 2 server
        ```

        - `--direction` is `right`, `left`, `down`, `up` or `auto` (along the longer side). The new pane starts
          in its source pane's directory, while a new tab starts in the project root. The reply's `panes[0]` is
          the new pane, with its `session`.
        - `macterm grid 2x2 --project api --tab 3 --run "tail -f log/dev.log"` splits a tab's focused pane (or
          the one named with `--session` or `--pane`) into an even grid, rows × columns, at most 16 cells.
          `--run` goes to every new pane; the source pane keeps its shell.
        - `macterm pane resize-split --session macterm-api-8f327ce4a3f8 --axis horizontal --ratio 0.6` moves the
          divider of the nearest side-by-side split around that pane (`--axis vertical` for a stacked one).
        - `macterm tab rename --project api 2 --reset` restores the automatic title, the running program's name.
        - `macterm tab move --project api 3 1` makes tab 3 the first tab.

        A tab that has never been on screen has no terminals yet, and that includes a new tab in a project the
        user isn't looking at: its `--run` commands wait and `pane run` answers `no_surface` until the tab is
        shown. A project not opened since Macterm launched has no tabs to add to at all. Build in the project
        on screen, or `macterm project select` the project first.

        ## 3. Save the layout, apply it later

        ```sh
        macterm layout save --project api
        ```

        writes the live workspace to `~/.config/macterm/projects/api.yaml`. The file is named after the project
        but matched to it by `path:`, never by its file name:

        ```yaml
        name: api
        path: ~/dev/api
        tabs:
          - name: server
            split:
              direction: vertical
              ratio: 0.5
              first: { run: "npm run dev" }
              second: { run: "npm test -- --watch" }
          - cwd: web
        ```

        - A tab is either one pane (`cwd`, `run` and `shell`, all optional; `{}` is a plain shell) or a `split`
          with a `direction` (`horizontal` is side by side, `vertical` is stacked), a `ratio` from 0 to 1
          (default 0.5), and `first` and `second` children, each a pane or another split. `name` titles the tab.
        - `cwd` is relative to the project root. `run` is typed into the pane's shell when the pane starts, so
          the shell is still there after the command exits. `shell` replaces the login shell for that pane.
        - Save records each pane's current foreground command as its `run:`, so save while the commands you
          want are running. The file is yours to edit afterwards, but the next `layout save` rewrites it.
        - Its first line names the schema:
          `https://raw.githubusercontent.com/thdxg/macterm/main/assets/project.schema.json`.

        ```sh
        macterm layout apply --project api
        ```

        reconciles the live tabs to the file: panes that match are kept, missing ones are created, and ones the
        file doesn't declare are closed. A pane with a `run:` matches a live pane running that command in that
        directory; a plain shell reuses any idle shell, wherever it is, so its `cwd` only applies to a pane
        that gets created. If the result would close any pane it answers `busy` and changes nothing: tell the
        user what would close, and re-run with `--force` only if they agree. A file that only adds tabs or
        panes applies at once.

        ## 4. What persists

        - **Quitting Macterm** detaches every pane's zmx session, and relaunching reattaches each one with its
          scrollback and running programs. Closing a pane, tab or project is what ends its sessions.
        - **A reboot** ends local sessions: those panes come back as fresh shells in their last directory,
          without their commands. Sessions of remote projects live on the host, so they survive it.
        - **The layout file** is applied only by an explicit `layout apply`, or Apply Layout in the app.
          Selecting a project or relaunching Macterm restores the last live state, never the file.
        - **Addresses:** session names never change. Pane ids are new at every launch, and `pane:N` numbers
          shift whenever a tab's splits change.
        - **Pinned tabs** belong to no project, sit above the projects in the sidebar and re-run their commands
          whenever their sessions did not survive, a reboot included. Pinning happens in the app; over the CLI
          `--project pinned` addresses them once one exists. They are declared in
          `~/.config/macterm/projects/pinned.yaml`, which Macterm maintains, and an edit there applies at the
          next launch. `layout save` and `layout apply` leave them alone.

        ## Windows

        ```sh
        macterm window list
        macterm window new
        macterm project select api --window 2
        macterm window close --window 2
        ```

        `window new` opens another window on the current project; `project select` and `tab select` take
        `--window` to act on a window other than the focused one. A tab open in two windows is live in one and
        mirrored in the other. The last window hides instead of closing.

        ## Remote projects

        A project's path can be a directory on another machine, `[user@]host:dir`. Use a `Host` alias from
        `~/.ssh/config` as the host: port, user and keys come from there, never from Macterm.

        ```sh
        macterm project create devbox:~/dev/api --name api-devbox
        ```

        Every pane of that project runs a zmx session on the host over ssh, and authentication happens
        interactively in the pane. zmx must already be installed there, on its `PATH` or in `~/bin` or
        `~/.local/bin`: a pane that prints `macterm: zmx not found in PATH on this host` needs it. Remote
        sessions survive quitting Macterm, dropped connections and local reboots. Commands typed into a remote
        pane run on the host, and so do any sentinel files they create.

        \#(currencyNote(for: "macterm-workspace"))
        """#
    )
}
