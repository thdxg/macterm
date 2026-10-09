extension AgentSkills {
    /// Building a workspace — project, tabs, splits, grids — and making it
    /// last: the layout file, what survives a quit or a reboot, windows, and
    /// remote projects.
    static let workspace = AgentSkill(
        name: "macterm-workspace",
        description: """
        Build a Macterm workspace and make it persist, with the macterm CLI. Find or create the project for a \
        directory, open tabs that run commands, split panes and grids, name tabs, then save the layout to its \
        YAML file in ~/.config/macterm/projects and apply it again later. It also explains what keeps running \
        after you quit Macterm or restart the Mac, and it covers windows and remote (ssh) projects. Use when \
        asked to set up, arrange, save or restore a Macterm project, tab or pane layout, to make a dev \
        environment come back with its commands running, or to add a local directory or a remote host as a \
        Macterm project.
        """,
        body: #"""
        # Building a Macterm workspace

        A project is a directory, or a directory on a remote host. It appears as a section of the sidebar of
        Macterm. It holds tabs. Each tab is a tree of split panes. Each pane is a shell that runs in a
        persistent zmx session. A window shows one project at a time.

        \#(groundRules)

        ## 1. Find the project, or create it once

        `project create` is not idempotent. Each call adds another project, also for the same directory. Look
        before you create:

        ```sh
        macterm project list --json
        ```

        Each project has an `id`, a `name` and a `path`. If a project already has your directory, select it.
        If not, create it one time:

        ```sh
        macterm project select api
        macterm project create ~/dev/api --name api --select
        ```

        `--select` makes the new project the active project. The active project is the project that the user
        looks at. In later commands, name projects by `name` or `id` (`--project api`). If two projects have
        the same name, the answer is `ambiguous`, so pass the `id`. `macterm project remove <id>` removes a
        duplicate. It does not touch any file, but it kills the sessions of that project.

        ## 2. Open tabs, split panes

        `tab new` opens a tab in the active project, unless you pass `--project`. The new tab becomes the active
        tab of that project, so the view of the user switches to it. `--run` types a command into its new
        shell:

        ```sh
        macterm tab new --project api --run "npm run dev" --json
        ```

        In the reply, `tabs[0]` has the `index` and the `id` of the new tab. Split that tab by naming it.
        Inside a pane, a split with no target splits the pane that you are in:

        ```sh
        macterm pane split --project api --tab 2 --direction down --run "npm test -- --watch" --json
        macterm tab rename --project api 2 server
        ```

        - `--direction` is `right`, `left`, `down`, `up` or `auto` (along the longer side). The new pane starts
          in the directory of its source pane. A new tab starts in the project root. In the reply, `panes[0]`
          is the new pane, with its `session`.
        - `macterm grid 2x2 --project api --tab 3 --run "tail -f log/dev.log"` splits the focused pane of a tab
          (or the pane that `--session` or `--pane` names) into an even grid of rows × columns. The grid has
          at most 16 cells. `--run` goes to every new pane. The source pane keeps its shell.
        - `macterm pane resize-split --session macterm-api-8f327ce4a3f8 --axis horizontal --ratio 0.6` moves
          the divider of the nearest side-by-side split around that pane (`--axis vertical` for a stacked
          split).
        - `macterm tab rename --project api 2 --reset` restores the automatic title, which is the name of the
          running program.
        - `macterm tab move --project api 3 1` makes tab 3 the first tab.

        Add `--no-focus` to `tab new` or `pane split` to start the new terminal with no change to the
        selection, the focus history or the zoom. If the app is too old for `--no-focus`, the command fails
        (exit 1) before it creates anything. It does not switch the focus in silence. The shell starts also in
        a hidden tab or project. Wait for its shell prompt before you use `pane run`. Without that flag, a tab
        in another project that nobody viewed can have no terminal yet. Its `--run` command waits, and
        `pane run` answers `no_surface` until someone views the tab. The target project must already be
        loaded. A project that was not opened since the start has no workspace to add tabs to.

        ## 3. Save the layout, apply it later

        ```sh
        macterm layout save --project api
        ```

        This writes the live workspace to `~/.config/macterm/projects/api.yaml`. The file has the name of the
        project, but Macterm matches it to the project by `path:`. It never uses the file name:

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

        - A tab is one pane (`cwd`, `run` and `shell`, all optional, and `{}` is a plain shell) or a `split`.
          A `split` has a `direction` (`horizontal` is side by side, `vertical` is stacked), a `ratio` from 0
          to 1 (the default is 0.5), and the children `first` and `second`. Each child is a pane or another
          split. `name` gives the tab a title.
        - `cwd` is relative to the project root. Macterm types `run` into the shell of the pane when the pane
          starts, so the shell is still there after the command exits. `shell` replaces the login shell for
          that pane.
        - Save records the current foreground command of each pane as its `run:`. Save while the commands that
          you want are running. You can edit the file afterwards, but the next `layout save` writes it again.
        - Its first line names the schema:
          `https://raw.githubusercontent.com/thdxg/macterm/main/assets/project.schema.json`.

        ```sh
        macterm layout apply --project api
        ```

        This changes the live tabs to match the file. Macterm keeps the panes that match. It creates the
        missing panes. It closes the panes that the file does not declare. A pane with a `run:` matches a live
        pane that runs that command in that directory. A plain shell reuses any idle shell, in any place, so its
        `cwd` applies only to a pane that Macterm creates. If the result would close a pane, the answer is
        `busy` and nothing changes. Tell the user what would close. Run the command again with `--force` only
        if the user agrees. A file that only adds tabs or panes applies at once.

        ## 4. What persists

        - **Quitting Macterm** disconnects the zmx session of every pane. When Macterm starts again, it
          connects each pane to its session again, with its scrollback and running programs. A session ends
          only when you close its pane, tab or project.
        - **A restart of the Mac** ends the local sessions. Those panes come back as new shells in their last
          directory, with no commands. The sessions of remote projects run on the host, so they keep running.
        - **The layout file** is applied only by an explicit `layout apply`, or by Apply Layout in the app.
          When you select a project or start Macterm again, Macterm restores the last live state. It never
          reads the file.
        - **Addresses:** session names never change. Pane ids are new at every start. The `pane:N` numbers
          change each time that the splits of a tab change.
        - **Pinned tabs** belong to no project. They are above the projects in the sidebar. They run their
          commands again each time that their sessions are gone, also after a restart of the Mac. You pin a
          tab in the app. In the CLI, `--project pinned` addresses the pinned tabs when one exists. They are
          declared in `~/.config/macterm/pinned.yaml`, which Macterm keeps up to date. An edit there applies
          at the next start. `layout save` and `layout apply` do not touch them.

        ## Windows

        ```sh
        macterm window list
        macterm window new
        macterm project select api --window 2
        macterm window close --window 2
        ```

        `window new` opens another window on the current project. `project select` and `tab select` accept
        `--window`, to act on a window other than the focused window. A tab that is open in two windows is live
        in one window and mirrored in the other. The last window hides and does not close.

        ## Remote projects

        The path of a project can be a directory on another machine, `[user@]host:dir`. Use a `Host` alias from
        `~/.ssh/config` as the host. Port, user and keys come from that file. They never come from Macterm.

        ```sh
        macterm project create devbox:~/dev/api --name api-devbox
        ```

        Every pane of that project runs a zmx session on the host over ssh. You sign in interactively in the
        pane. zmx must already be on the host, in its `PATH` or in `~/bin` or `~/.local/bin`. A pane that
        prints `macterm: zmx not found in PATH on this host` needs it. Remote sessions keep running when you
        quit Macterm, when the connection drops and when you restart the Mac. Commands that you type into a
        remote pane run on the host. The sentinel files that they create are on the host too.

        \#(currencyNote(for: "macterm-workspace"))
        """#
    )
}
