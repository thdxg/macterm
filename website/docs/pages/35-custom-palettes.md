<!-- page:
slug: custom-palettes
title: Custom palettes
nav: Custom palettes
group: Everyday use
description: Add your own screens to the command palette from YAML files — a command's output becomes searchable rows, and each row opens another screen or runs a command.
-->

# Custom palettes

A custom palette is your own screen in the [command palette](/docs/command-palette): Git branches, Docker containers, SSH hosts, Kubernetes pods — anything a command can list. Each palette is one YAML file in `~/.config/macterm/palettes/`. It shows up in the palette's **Palettes** section with a chevron, and picking it opens its screen in place.

Macterm reads the folder again every time the palette opens, so saving the file is all it takes. There is nothing to reload or restart.

## A first palette

```yaml title="~/.config/macterm/palettes/git.yaml"
# yaml-language-server: $schema=https://raw.githubusercontent.com/thdxg/macterm/main/assets/palette.schema.json
name: Git
icon: arrow.triangle.branch
description: The current project's branches
root: branches
nodes:
  branches:
    list: git branch --format='%(refname:short)'
    export: { BRANCH: . }
    enter: branch
  branch:
    items:
      - { title: Switch to it, action: { run: git switch "$BRANCH", in: split } }
      - { title: Log, action: { run: git log --oneline --graph "$BRANCH", in: split } }
      - { title: Diff against HEAD, action: { run: git diff HEAD..."$BRANCH", in: split } }
```

Press <kbd>⌘P</kbd>, type `git`, and press <kbd>Return</kbd>. The screen lists the active project's branches. Pick one and a second screen offers what to do with it. The pills above the palette read **Git › main**. Pick **Log** and `git log` runs in a split beside the focused pane.

## The file

| Key | |
| --- | --- |
| `name` | Required. The palette's row, its pill, and its row in Settings. |
| `icon` | An [SF Symbol](https://developer.apple.com/sf-symbols/) name. Defaults to `square.grid.2x2`. |
| `description` | One line under the palette's row in the command palette and in Settings → Palettes. |
| `root` | The node the palette opens on. Defaults to a node named `root`. |
| `nodes` | Required. Every screen of the palette, by name. |

The file's name without `.yaml` is the palette's id. Its switch in Settings and its keybind are stored under that id, so renaming the file loses both.

## Nodes

A node is one screen. Its rows are written out (`items:`), listed by a command (`list:`), or both.

**A menu** has `items:`, rows you write out:

```yaml
menu:
  items:
    - { title: Branches, subtitle: Local only, enter: branches }
    - { title: Fetch, icon: arrow.down.circle, action: { run: git fetch --all --prune } }
```

Each item takes `title` (required), `subtitle`, `icon`, `export`, either `enter` or `action`, and optionally `alt`. Every value in a menu item is literal.

**A listing** has `list:`, a command whose output becomes the rows:

```yaml
pods:
  list: kubectl get pods -A -o json
  rows: .items
  title: .metadata.name
  subtitle: .status.phase
  match: [.metadata.name, .metadata.namespace, .metadata.labels.app]
  export: { POD: .metadata.name, NAMESPACE: .metadata.namespace }
  action: { run: kubectl logs -f -n "$NAMESPACE" "$POD", in: split }
```

| Key | |
| --- | --- |
| `list` | The command. It runs once when the screen opens. |
| `rows` | When the output is one JSON object, the path to its array of rows. |
| `title` | Each row's title. Defaults to `.`, the whole row. A row whose title comes out empty is left out. |
| `subtitle` | Each row's second line. |
| `icon` | An SF Symbol for every row, or a path to one. |
| `match` | What the search looks in. Defaults to the title and subtitle. Add the fields people search by, such as an app label. |
| `export` | Variables each row sets for the screens below it. |
| `enter` / `action` | What every row does when picked: open that node, or perform the action. |
| `alt` | What every row does on <kbd>⌥↩</kbd> or <kbd>⌥</kbd>-click instead. See [Alt actions](#alt-actions). |
| `placeholder` | The search field's placeholder on this screen. Any node can have one. |

Every row has exactly one of `enter:` or `action:`.

**A node can have both.** Its written items come first and show at once; the listing's rows follow when its command finishes. This puts a few fixed rows above a list, such as **New Session** above the most recent sessions:

```yaml
root:
  items:
    - { title: New Session, action: { run: claude } }
    - { title: All Sessions, enter: sessions }
  list: ./recent-sessions --limit 3
  export: { SESSION: . }
  action: { run: claude --resume "$SESSION" }
```

In a node with both, `title`, `export`, `enter`, `action` and the other listing keys describe the listing's rows; each item has its own.

### Paths

In a listing, a value that starts with `.` is a path into the row. Anything else is literal text.

- `.` is the row itself. For plain-line output, that is the whole line.
- `.metadata.name` is a field, and `.items[0].name` an element of an array.
- Inside a `{ }` mapping, quote a path with an index, as in `PORT: '.spec.ports[0].port'`. Otherwise YAML reads the brackets as a list. The same goes for a value containing `: ` or ` #`.

### Command output

A listing's output can be any of these:

- A JSON array of rows.
- Newline-delimited JSON objects, one row per line, like `docker ps --format json` or `jq -c '.items[]'`.
- One JSON object with the rows inside it, found by `rows:`.
- Plain lines, one row each, when the output doesn't start with `[` or `{`.

Prefer a tool's JSON output to cutting up its text. JSON gives you named fields for `title`, `subtitle` and `match`.

## Exports

`export:` sets environment variables for every command below the row: the next screen's listing, and any action further down. Values carry down through every screen, and a lower screen can overwrite one.

Read an exported value as a variable, like `"$BRANCH"`. **Nothing is ever pasted into a command's text**, so a branch, pod or file name with spaces or quotes can't break the command or run as code.

One node can be reached from several places. In the [Kubernetes palette](/docs/cookbook#kubernetes-palette), **Pods** opens from the root with no namespace and from a namespace with one. The command handles both cases, as a shell script would:

```yaml
list: if [ -n "$NAMESPACE" ]; then set -- -n "$NAMESPACE"; else set -- -A; fi; kubectl get pods "$@" -o json
```

## Actions

An action is exactly one of these:

| Action | Does |
| --- | --- |
| `run: <command>` | Types the command into a new tab of the active project, or with `in: split` into a split beside its focused pane. The exported variables are in that terminal's environment. |
| `copy: <text>` | Copies to the clipboard. In a listing, a path or literal text. |
| `open: <url or file>` | Opens with the default app. In a listing, a path or literal text. |

A `run:` command is typed at the new terminal's prompt, the way a [layout's](/docs/declarative-layouts) `run:` is. When the command ends, the shell is still there.

### Alt actions

A row can have a second action, `alt:`, run by <kbd>⌥↩</kbd> or <kbd>⌥</kbd>-click. While <kbd>⌥</kbd> is held, the row's subtitle says what it will do: the alt's `title:`, or else what the action is (**Run in a Split**, **Run in a New Tab**, **Copy**, **Open**).

```yaml
- title: New Session
  action: { run: claude }
  alt: { title: New Session in a Split, run: claude, in: split }
```

`alt:` takes the same keys as `action:`, plus `title:`. It goes on a menu item, or on a listing for every row, and works on a row that enters a node too.

## Commands and your shell

Commands run in **your login shell**, as `$SHELL -l -c '<command>'`. Write them in that shell's syntax, and they see the `PATH` your shell config sets up. A listing runs in the active project's directory.

Every command also gets these variables:

- `MACTERM_PROJECT_DIR`, the active project's directory.
- `MACTERM_PROJECT_NAME`, its name.
- Every value exported above it.

The examples on this page are POSIX shell, which zsh and bash also read. In nushell, read a variable as `$env.BRANCH`. A value that may be missing is `$env.NAMESPACE?`. The Pods listing above becomes:

```yaml
list: 'kubectl get pods ...(if ($env.NAMESPACE? | is-empty) { ["-A"] } else { ["-n", $env.NAMESPACE] }) -o json'
```

**A shell that prints at startup prints into the rows.** A greeting or notice from your shell config becomes the first row of every listing. Keep startup quiet for non-interactive shells.

## Loading and errors

- **While a listing runs**, the screen shows a spinner. One that takes over 30 seconds is stopped.
- **If a listing fails**, the screen says why, with the command's error output. A listing fails when the command isn't found, exits non-zero, or prints output that isn't the shape asked for. **Retry**, or <kbd>⌘R</kbd>, runs it again.
- **A file that doesn't read** keeps its row, with a warning glyph before the chevron. Entering it shows the error, naming the node and key, like `pods: enter: no node named pod`. Fix the file and press <kbd>⌘R</kbd>. Settings → Palettes shows the same warning beside the palette's switch.

To check every file from a terminal, run:

```sh
macterm palette list
```

It prints each file's id, whether it is on, its keybind, and its name or the error that stopped it reading. See [the CLI](/docs/cli).

## Keybinds and Settings

- **Settings → Palettes** lists every palette, built-in and custom, each with a switch. A palette turned off leaves the command palette, and its keybind says so instead of reaching the terminal. The **Palettes folder** row opens `~/.config/macterm/palettes/` in Finder.
- **Settings → Keymaps** has a **Palettes** group first, with <kbd>⌘P</kbd> and a row for every palette. None has a keybind by default. A palette's keybind opens the command palette straight on it. Pressed again on the palette's first screen, it closes the palette. Pressed deeper in, it goes back to that first screen.
- **Any palette's keybind, built-in or custom, can be Global or Pass to TUI**, the two checkboxes on its row. A **Global** keybind works from any app: it brings Macterm's window forward with the palette open on it. **Pass to TUI** hands the keybind to the program in the focused pane when that program is one you list under Passthrough Programs.

## More examples

### Docker containers

```yaml title="~/.config/macterm/palettes/docker.yaml"
name: Docker
icon: cube.box
description: Running containers, their logs and a shell in them
root: containers
nodes:
  containers:
    list: docker ps --format json
    title: .Names
    subtitle: .Image
    match: [.Names, .Image, .Status]
    export: { CONTAINER: .ID }
    enter: container
  container:
    items:
      - { title: Logs, subtitle: Follow in a split, action: { run: docker logs -f "$CONTAINER", in: split } }
      - { title: Shell, action: { run: docker exec -it "$CONTAINER" sh, in: split } }
      - { title: Stop, action: { run: docker stop "$CONTAINER" } }
```

### SSH hosts

The hosts named in `~/.ssh/config`, leaving out wildcard patterns. Hosts in an `Include`d file aren't listed.

```yaml title="~/.config/macterm/palettes/ssh.yaml"
name: SSH Hosts
icon: server.rack
description: Hosts from ~/.ssh/config
root: hosts
nodes:
  hosts:
    list: awk 'tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i !~ /[*?!]/) print $i }' ~/.ssh/config
    export: { HOST: . }
    enter: host
  host:
    items:
      - { title: Connect, action: { run: ssh "$HOST" } }
      - { title: Connect in a split, action: { run: ssh "$HOST", in: split } }
```

### Kubernetes

Namespaces, pods, deployments, services and contexts, five screens deep. It's in the cookbook: [Kubernetes palette](/docs/cookbook#kubernetes-palette).

## Writing one with a coding agent

Macterm ships a skill that teaches coding agents this format. Print it with:

```sh
macterm skills macterm-palettes
```

See [skills for coding agents](/docs/cli#skills-for-coding-agents). For editors that understand `yaml-language-server`, the schema is at [`assets/palette.schema.json`](https://raw.githubusercontent.com/thdxg/macterm/main/assets/palette.schema.json). The comment at the top of the first example points an editor at it.
