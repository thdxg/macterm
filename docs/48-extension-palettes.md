<!-- page:
slug: extension-palettes
title: Palette reference
nav: Palette reference
group: Extensions
description: Every key of a palette file in a Macterm extension. Nodes, listings, paths, exports, actions, alt actions, checks, and how commands run in your shell.
-->

# Palette reference

A palette is one YAML file in the `palettes/` folder of an [extension](/docs/extensions). This page gives every key of that file. To make your first palette, start with [a first extension](/docs/extensions#a-first-extension).

## The palette file

| Key | |
| --- | --- |
| `name` | Required. The row of the palette, its pill, and its row in Settings. |
| `description` | One line under the row of the palette in the command palette, and on its card in Settings → Extensions. |
| `root` | The node that the palette opens on. The default is a node with the name `root`. |
| `requires` | The programs that its commands need, for example `[kubectl, jq]`. When a listing fails, the error names each of these programs that is not in your `PATH`. |
| `when` | Whether the palette can be used now: a check command and the reason to show when the check fails. See [when a palette can't be used](#when-a-palette-cant-be-used). |
| `nodes` | Required. Every screen of the palette, by name. |

The id of a palette is the name of its extension folder and its file name without `.yaml`, for example `git/branches`. Macterm stores its keybind under that id. If you rename the file or the folder, you lose the keybind.

## Nodes

A node is one screen. Its rows are written out (`items:`), listed by a command (`list:`), or both.

**A menu** has `items:`. These are rows that you write out:

```yaml
menu:
  items:
    - { title: Branches, subtitle: Local only, enter: branches }
    - { title: Fetch, icon: arrow.down.circle, action: { run: git fetch --all --prune } }
```

Each item takes `title` (required), `subtitle`, `icon`, `export`, `enter` or `action`, and optionally `alt` and `when`. Every value in a menu item is literal.

**A listing** has `list:`. This is a command whose output becomes the rows:

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
| `list` | The command. It runs one time when the screen opens. |
| `rows` | When the output is one JSON object, the path to its array of rows. |
| `title` | The title of each row. The default is `.`, the whole row. Macterm leaves out a row with an empty title. |
| `subtitle` | The second line of each row. |
| `icon` | An SF Symbol for every row, or a path to one. |
| `match` | What the search looks in. The default is the title and the subtitle. Add the fields that people search by, for example an app label. |
| `export` | Variables that each row sets for the screens below it. |
| `enter` / `action` | What every row does when you select it: open that node, or run the action. |
| `alt` | What every row does on <kbd>⌥↩</kbd> or <kbd>⌥</kbd>-click instead. See [Alt actions](#alt-actions). |
| `placeholder` | The placeholder of the search field on this screen. Any node can have one. |

Every row has exactly one of `enter:` or `action:`.

**A node can have both.** Its written items come first and show at once. The rows of the listing follow when its command finishes. Use this to put a few fixed rows above a list. An example is **New Session** above the most recent sessions:

```yaml
root:
  items:
    - { title: New Session, action: { run: claude } }
    - { title: All Sessions, enter: sessions }
  list: ./recent-sessions --limit 3
  export: { SESSION: . }
  action: { run: claude --resume "$SESSION" }
```

In a node that has both, `title`, `export`, `enter`, `action` and the other listing keys describe the rows of the listing. Each item has its own keys.

### Paths

In a listing, a value that starts with `.` is a path into the row. Any other value is literal text.

- `.` is the row itself. For plain-line output, it is the whole line.
- `.metadata.name` is a field. `.items[0].name` is an element of an array.
- Inside a `{ }` mapping, put quotes around a path with an index, as in `PORT: '.spec.ports[0].port'`. Without quotes, YAML reads the brackets as a list. The same is true for a value that contains `: ` or ` #`.

### Command output

The output of a listing can be one of these:

- A JSON array of rows.
- Newline-delimited JSON objects, one row on each line, such as `docker ps --format json` or `jq -c '.items[]'`.
- One JSON object with the rows inside it. `rows:` finds them.
- Plain lines, one row each. This applies when the output does not start with `[` or `{`.

Use the JSON output of a tool when you can. Do not cut up its text. JSON gives you named fields for `title`, `subtitle` and `match`.

## Exports

`export:` sets environment variables for every command below the row. These are the listing of the next screen, and each action further down. The values pass down through every screen. A lower screen can overwrite a value. A name must be a name that `sh` can read (letters, digits and `_`, and it does not start with a digit). It must not be a name that Macterm sets itself (`MACTERM_PROJECT_DIR`, `MACTERM_PROJECT_NAME`, `MACTERM_EXTENSION_DIR`).

Read an exported value as a variable, such as `"$BRANCH"`. **Macterm never pastes a value into the text of a command**. The name of a branch, a pod or a file can have spaces or quotes. These characters cannot break the command. They cannot run as code.

You can reach one node from several places. In the [Kubernetes extension](/docs/extension-examples#the-extensions-in-the-repository), **Pods** opens from the root with no namespace. It also opens from a namespace with one. The command handles both cases, as a shell script does:

```yaml
list: if [ -n "$NAMESPACE" ]; then set -- -n "$NAMESPACE"; else set -- -A; fi; kubectl get pods "$@" -o json
```

## Actions

An action is exactly one of these:

| Action | What it does |
| --- | --- |
| `run: <command>` | Runs the command in a new tab of the active project. With `in: split`, it runs in a split next to the focused pane. If a pinned tab is active, it always runs in a split next to that tab. The exported variables are in its environment. |
| `cwd: <directory>` | Opens a shell in the directory, in a new tab of the active project. With `in: split`, it opens in a split next to the focused pane. With `run:`, the command runs in that directory. In a listing, the value is a path or literal text. |
| `copy: <text>` | Copies the text to the clipboard. In a listing, the value is a path or literal text. |
| `open: <url or file>` | Opens the URL or file with the default app. In a listing, the value is a path or literal text. |

A `run:` command runs before the shell of the new terminal starts. When the command ends, you see the shell prompt of your shell. **Macterm never types the command at the shell prompt.** The command stays out of the history of your shell.

A relative `cwd:` is relative to the project directory. The directory must exist. If it does not exist, Macterm shows a message and opens nothing. This listing opens each worktree of the repository in a new tab, and <kbd>⌥↩</kbd> opens it in a split:

```yaml
worktrees:
  list: git worktree list --porcelain | sed -n 's/^worktree //p'
  action: { cwd: . }
  alt: { cwd: ., in: split }
```

**A `cwd:` is a directory on your Mac**, where every listing runs. In a [remote project](/docs/remote-projects), Macterm does not open a terminal for a `cwd:` action, and shows a message.

**In a [remote project](/docs/remote-projects), Macterm types a `run:` command at the shell prompt of the host**, as you wrote it. ssh does not carry an environment to the host. The own shell of the host runs the command. It does not run in `sh`, and a shebang has no meaning there. The command enters the history of that shell. **The exported variables and `MACTERM_PROJECT_*` are not set.** A palette for remote projects therefore cannot pass a selection to `run:` through `"$VAR"`.

### Alt actions

A row can have a second action, `alt:`. <kbd>⌥↩</kbd> or <kbd>⌥</kbd>-click runs it. While you hold <kbd>⌥</kbd>, the subtitle of the row says what the alt action does. It shows the `title:` of the alt action. If there is no title, it shows the kind of action (**Run in a Split**, **Run in a New Tab**, **Open in a Split**, **Open in a New Tab**, **Copy**, **Open**).

```yaml
- title: New Session
  action: { run: claude }
  alt: { title: New Session in a Split, run: claude, in: split }
```

`alt:` takes the same keys as `action:`, and also `title:`. Put it on a menu item, or on a listing for every row. It also works on a row that enters a node.

## Commands and your shell

**Commands are POSIX `sh`.** `sh -o errexit` runs them exactly as you wrote them, for any shell that you use. A palette therefore works in the same way for everyone who gets it. The command reaches `sh` in an environment variable. Macterm never pastes it into a shell line, so nothing in it needs escaping. With errexit, a command with several steps stops at the first step that fails. A listing runs in the directory of the active project. For a remote project or a pinned tab, it runs in your home folder on your Mac.

**A command that starts with a shebang runs as a script** with that interpreter. This is how [mise](https://mise.jdx.dev/tasks/toml-tasks.html) runs a task. Write it as a YAML block:

```yaml
list: |
  #!/usr/bin/env nu
  ls | where type == dir | get name | to json
```

Commands still see **the environment of your shell**. Macterm starts them through your login shell, so the `PATH` that it sets finds `kubectl`, `jq` or the interpreter of the shebang:

- **A listing** starts through a non-interactive login shell. This shell reads your login files (`.zprofile`, `.bash_profile`, `env.nu` and `config.nu` of nushell). It does not read `.zshrc` or `.bashrc`. Set the `PATH` that a listing needs in a login file.
- **A `run:` command** starts through an interactive login shell. What your `.zshrc` exports reaches the command too.

The aliases and functions of your shell reach neither one. They are not `sh`.

Every command also gets these variables:

- `MACTERM_PROJECT_DIR`: the directory of the active project. It is not set for a remote project or a pinned tab.
- `MACTERM_PROJECT_NAME`: the name of the project.
- `MACTERM_EXTENSION_DIR`: the folder of the extension that has the palette. A command can use it to run a script that is in that folder.
- Every value that is exported above it.

**Text that your shell prints at startup goes into the rows**. A greeting or a notice from your shell config becomes the first row of each listing. Keep the startup of non-interactive shells quiet.

## When a palette can't be used

`when:` mutes a palette, or a row of a menu, when a check says that it cannot be used now. Examples: a cluster that does not answer, a tool that is not set up, a project that is not the right kind:

```yaml
when: { run: kubectl get --raw /readyz --request-timeout=2s, unavailable: Cluster unreachable }
```

- **`run:`** is a command like any other command in the palette (POSIX `sh`, or a script with a `#!` line). It has the same environment and directory as a listing. The check passes when the command exits with 0. The command has 10 seconds. If it takes longer, the check fails.
- **`unavailable:`** is the text that the muted row shows in place of its subtitle. Without it, the row says *Unavailable*.

**On the palette** (next to `name:`), the check runs each time that you open the command palette. **On a menu item**, it runs each time that the screen of the item opens. In both cases it runs in the background. The row is usable until the check fails. Then the row is muted. You cannot select it, and it says why. Macterm remembers nothing. The next time that the palette opens, it checks again.

**When you open a palette with its keybind**, Macterm checks first and shows a spinner. If the check fails, it says why and does not show the list. <kbd>⌘R</kbd> checks again.

Items that share a check run it one time for each screen. Name the check one time with a YAML anchor and use it again:

```yaml
- { title: Pods, enter: pods, when: &cluster { run: kubectl get --raw /readyz --request-timeout=2s, unavailable: Cluster unreachable } }
- { title: Services, enter: services, when: *cluster }
- { title: Contexts, enter: contexts }
```

Macterm does not check the rows of a listing one by one. Put `when:` on the item that opens the listing.

## Loading and errors

- **While a listing runs**, the screen shows a spinner. If a listing takes more than 30 seconds, Macterm stops it, and it stops everything that the listing started. If you leave the screen, Macterm also stops the listing.
- **If a listing fails**, the screen says why. It shows the error output of the command. A listing fails in three cases. The command is not found. The command exits with a non-zero code. The output has the wrong shape. If a program that the palette `requires` is missing, the screen names that program. For example: *This palette needs kubectl, which is not on your PATH.* To run the listing again, select **Retry** or press <kbd>⌘R</kbd>.
- **A file that Macterm cannot read** keeps its row, with a warning glyph before the chevron. When you enter the row, it shows the error and names the node and the key, for example `pods: enter: no node named pod`. A key that Macterm does not know is also an error (`pods: mathc: no such key`). A misspelling therefore cannot do nothing in silence. Fix the file and press <kbd>⌘R</kbd>. Settings → Extensions shows the same warning on the card of the extension.

To check every file from a terminal, run:

```sh
macterm palette list
```

The command prints the id of each palette, its keybind, and its name or the error that stopped Macterm from reading it. See [the CLI](/docs/cli).
