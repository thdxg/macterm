extension AgentSkills {
    /// Writing a custom command-palette screen: the YAML file, its nodes,
    /// how a command's output becomes rows, how selections travel down as
    /// environment variables, and how to check the file reads.
    static let palettes = AgentSkill(
        name: "macterm-palettes",
        description: """
        Create or edit a custom Macterm command-palette screen as a YAML file in ~/.config/macterm/palettes — \
        a palette of named nodes where a command's JSON or plain-line output becomes searchable rows, each row \
        opens another node or runs a command in a new tab or split, and picked values travel down as environment \
        variables — then check with the macterm CLI that the file reads. Use when asked to add a palette, picker, \
        launcher or quick-switcher to Macterm for things like Kubernetes namespaces and pods, Docker containers, \
        git branches, SSH hosts, cloud resources, projects or scripts, or to fix a palette file that shows an error.
        """,
        body: #"""
        # Writing a Macterm palette

        A custom palette is one YAML file in `~/.config/macterm/palettes/`. It appears as a row in the command
        palette's **Palettes** section (⌘P), opens a screen of its own, and can nest: a row can open another
        screen, and the pills above the palette show the trail. Macterm reads the folder again every time the
        palette opens, so saving the file is the whole deploy. A file that doesn't read keeps its row with a
        warning glyph; entering it shows the error, and ⌘R reads the file again.

        \#(groundRules)

        ## The file

        ```yaml
        # ~/.config/macterm/palettes/kubernetes.yaml
        # yaml-language-server: $schema=https://raw.githubusercontent.com/thdxg/macterm/main/assets/palette.schema.json
        name: Kubernetes
        icon: shippingbox                      # an SF Symbol name; optional
        description: Namespaces, pods and their logs
        root: menu                             # the node to open on; defaults to a node called root
        nodes:
          menu:
            items:
              - { title: Namespaces, enter: namespaces }
              - { title: Pods, subtitle: All namespaces, enter: pods }
          namespaces:
            list: kubectl get ns -o json
            rows: .items
            title: .metadata.name
            export: { NAMESPACE: .metadata.name }
            enter: namespace-menu
          namespace-menu:
            items:
              - { title: Pods, enter: pods }
              - { title: Set as current context, action: { run: kubectl config set-context --current --namespace "$NAMESPACE" } }
          pods:
            list: kubectl get pods ${NAMESPACE:+-n "$NAMESPACE"} ${NAMESPACE:--A} -o json
            rows: .items
            title: .metadata.name
            subtitle: .status.phase
            match: [.metadata.name, .metadata.namespace, .metadata.labels.app]
            export: { POD: .metadata.name, NAMESPACE: .metadata.namespace }
            action: { run: kubectl logs -f -n "$NAMESPACE" "$POD", in: split }
        ```

        - `name` and `nodes` are required. The file's stem (`kubernetes`) is the palette's id: Settings and
          keybinds key on it, so don't rename the file once the user has set those.
        - A **node** is a menu (`items:`, rows you write) or a listing (`list:`, a command whose output becomes
          rows), never both. Every row — each item of a menu, every row of a listing — has exactly one of
          `enter:` (a node name) or `action:`.
        - **`export`** sets environment variables for everything below the row: in a menu item the values are
          literal, in a listing they are paths into the row. A node can be reached from several places (`pods`
          above, with and without `NAMESPACE`); the command handles the difference the way a shell does.
        - An **action** is exactly one of `run:` (typed into a new tab, or a split with `in: split`, with the
          exported variables in its environment), `copy:` (to the clipboard) or `open:` (a URL or file).

        ## Commands and their output

        - Commands run in the user's **login shell** with `-l -c`, so write them in that shell's syntax (ask
          or check `$SHELL`; it may be nushell or fish) and rely on its `PATH`. A listing runs once when its
          screen opens, in the active project's directory, with `MACTERM_PROJECT_DIR`, `MACTERM_PROJECT_NAME`
          and the exported variables set. ⌘R runs it again. One that takes over 30 seconds fails.
        - **Read exported values as variables** (`"$NAMESPACE"`), never by pasting them into another command:
          Macterm never substitutes a row's text into a command, so a value with spaces or quotes can't break
          one. Keep that property in anything you write.
        - A listing's **output** is JSON — an array, newline-delimited objects (`jq -c '.items[]'`), or an
          object with the rows at `rows:` — or, when it doesn't start with `[` or `{`, plain lines, one row each
          (`git branch --format='%(refname:short)'`, `ls`).
        - In a listing node a value starting with `.` is a **path** into the row: `.` the row itself (the
          whole line for plain output), `.metadata.name` a field, `.items[0].name` an index. Anything else is
          literal. `title:` defaults to `.`; `match:` (what the search looks in) defaults to the title and
          subtitle; `subtitle`, `icon`, `export`, `copy` and `open` take paths too. A row whose title resolves
          to nothing is dropped. Inside a `{ }` flow mapping, quote a path with an index — `PORT: '.spec.ports[0].port'` —
          or YAML reads the brackets as a list; the same goes for a value holding `: ` or ` #`.
        - Prefer `-o json` / `--format json` / `--json` output with `rows:` over text munging, and name the
          fields users search by in `match:` (an app label, a host, a branch) so a search finds a pod by its
          deployment.

        ## Check it reads

        ```sh
        macterm palette list
        ```

        Lists every palette file with its name, whether it is on, and — for a file that didn't read — the error
        on the line, naming the node and field (`pods: enter: no node named pod`). Fix and run it again; the
        palette itself is opened with ⌘P (there is no CLI verb for that). Never run a listing's command yourself
        to "test" it if it has side effects; the user's shell runs it.

        ## Keeping it theirs

        - Pick the icon from SF Symbols; `square.grid.2x2` is the default.
        - Don't put secrets in the file: it is plain text in the user's config directory.
        - Settings → Palettes turns a palette off without deleting it, and Settings → Keymaps gives it a
          keybind. Mention both rather than doing either for the user.

        \#(currencyNote(for: "macterm-palettes"))
        """#
    )
}
