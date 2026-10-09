<!-- page:
slug: cli
title: The macterm CLI
nav: CLI
group: Automation
description: Control the running app (projects, tabs, panes and sessions) from scripts and AI agents over a local socket.
-->

# The `macterm` CLI

The `macterm` command controls the **running app**: projects, tabs, panes and their zmx sessions. It uses a local Unix socket.

Each shell that Macterm starts already has `macterm` in its `PATH`:

```console
$ macterm status
Macterm 1.4.0 (pid 4242) — active project: api

$ macterm tab new --run "npm run dev"
tab:3  *  npm  1 pane

$ macterm grid 2x2 --run "tail -f log/dev.log"
```

In any other shell, use the bundle path, or make a symlink to it in a folder in your `PATH`:

```sh
/Applications/Macterm.app/Contents/Resources/bin/macterm status
```

Every command that talks to the app accepts `--json` for a payload that a script can read. It also accepts `--socket <path>` to select one instance of the app. `--help` works at every level.

## Commands

The grammar is `macterm <noun> <verb> [options]`. A noun with no verb means `list`.

| Command | Description |
|---|---|
| `status` | Shows the version, the pid and the active project. Exits with a non-zero code if no app is reachable. |
| `project list` | Lists all projects with refs (`project:1`), active and loaded markers, and tab counts. |
| `project create <path> [--name N] [--select]` | Adds a project for a local directory or a [remote spec](/docs/remote-projects). **It is not idempotent.** Each run adds a new project. `--name` defaults to the name of the directory and cannot be empty. `Pinned` is a reserved name. `--name Pinned` is refused, and a directory with the name Pinned is added as `Pinned 2`. |
| `project select <name\|uuid\|index> [--window W]` | Makes a project active. `pinned` selects the pinned tabs. |
| `project rename <project> <name>` | Renames a project. `Pinned` is a reserved name. |
| `project remove <project> [--force]` | Removes a project and kills its sessions. Returns `busy` when a pane runs a program, unless you use `--force`. It does not touch your files. |
| `tab list [--project P]` | Lists the tabs of a project (default: the active project). |
| `tab new [--project P] [--run CMD] [--no-focus]` | Makes a new tab. The tab becomes active unless you use `--no-focus`. `--run` types CMD into the new shell. |
| `tab select <tab> [--window W]` | Makes a tab active (`tab:3`, an index, a UUID, or an exact title). |
| `tab move <tab> <slot>` | Changes the order of a tab. `slot` is the **final** position, counted from 1. |
| `tab rename <tab> [title] [--reset]` | Renames a tab, or restores the automatic title. |
| `tab close <tab> [--force]` | Closes a tab and kills its sessions. Returns `busy` when a pane runs a program. If you close a pinned tab, Macterm unloads it. |
| `window list` | Lists the open windows in the order of their creation (`window:1`). |
| `window new` | Opens another window on the current project. |
| `window focus <window>` | Brings a window to the front. |
| `window close [--window W]` | Closes a window. The last visible window hides instead. |
| `widget list` | Lists the [desktop widgets](/docs/desktop-widgets) in the order of their creation (`widget:1`), with name, size, locked or editing state, and session name. |
| `widget new [--size S] [--name N] [--run CMD]` | Adds a locked desktop widget that runs your login shell, in the middle of the desktop. `S` is a grid span, `COLUMNSxROWS`, for example `3x2`. The default is `3x3`. `--run` types CMD into the shell each time that the widget starts one. |
| `widget set <widget> --size S` | Changes the size of a widget. It snaps to the grid. |
| `widget edit <widget>` | Unlocks a widget for typing, moving and resizing. Returns `busy` while you edit another widget. |
| `widget done` | Locks the widget that you edit. |
| `widget remove <widget> [--force]` | Removes a widget and ends its shell. Returns `busy` when a program runs in it, unless you use `--force`. |
| `palette list` | Lists the palettes of the installed [extensions](/docs/extensions), in `~/.config/macterm/extensions`. It reads them again each time. It shows the id (`<extension>/<file>`), the keybind, and the name of the palette or the error that stopped Macterm from reading the file. |
| `pane list [--project P] [--tab T]` | Lists panes with refs, session names, cwd, foreground process and execution state. |
| `pane inspect [target]` | Shows a snapshot of the terminal core of a pane. It needs a live surface. |
| `pane dump [--scrollback] [target]` | Prints the terminal text of a pane. It prints text only, so you can use it in a pipeline. |
| `pane split [--direction right\|left\|down\|up\|auto] [--run CMD] [--no-focus] [target]` | Splits a pane. The new pane gets the cwd of the pane. `auto` selects the longer axis. `--no-focus` keeps the current focus and zoom. |
| `pane mirror [--direction …] [target]` | Shows the same session in a second pane. When you focus a mirror, it becomes the leader and the other pane dims. |
| `pane focus <target>` | Focuses a pane. It selects the tab, brings the window forward and restores keyboard focus. |
| `pane focus --direction left\|down\|up\|right [target]` | Focuses the nearest pane in that direction. At the outermost edge, it does nothing and gives no error. |
| `pane close (--pane P \| --session S) [--force]` | Closes a pane. It always needs an explicit target. |
| `pane run [--no-submit] [target] -- <command…>` | Types a command and a newline into a live pane. `--no-submit` leaves the text at the shell prompt. See [Typing into a pane](#typing-into-a-pane). |
| `pane key <chord> [target]` | Sends one key press (`a`, `ctrl+c`, `escape`, `up`). |
| `pane zoom [target]` | Turns zoom on or off for a pane. |
| `pane resize-split --axis horizontal\|vertical --ratio R [target]` | Sets the ratio (0.15 to 0.85) of the nearest split on that axis. |
| `grid <RxC> [--run CMD] [target]` | Splits a pane into an equal grid of R×C panes (16 cells at most). `--run` starts CMD in every new pane. |
| `session list` / `session info <name>` | Lists zmx sessions and shows which pane is connected to each one. |
| `session kill <name>` | Kills a session. The shell of a connected pane exits. |
| `layout apply [--project P] [--force]` | Changes the workspace to match the [layout file](/docs/declarative-layouts) of the project. Returns `busy` instead of closing panes. |
| `layout save [--project P]` | Writes the live workspace to `~/.config/macterm/projects/<slug>.yaml`. |
| `tutor [project\|pinned]` | Prints a short tutorial with your own keybinds. It needs a running app. |
| `ssh <ssh args…>` | Runs ssh with the terminal integration of Macterm. It needs no running app. The flags are the flags of `ghostty +ssh`: `--terminfo=false`, `--forward-env=false`, `--cache=false` and `--verbose`. |
| `skills [name] [--list]` | Prints [skills for coding agents](#skills-for-coding-agents): all of them after the install instructions, or one `SKILL.md` as it is. It needs no running app. |

## Starting a background terminal

`tab new --no-focus` starts the shell of a tab and does not change the selected tab. An empty workspace takes its first tab with no focus history. `pane split --no-focus` starts a split and does not move the pane focus or clear the zoom. Neither command switches projects or windows. This is also true when the target project or tab is not visible. In a project that you unloaded, only the tab that started becomes undimmed. A background split also starts the existing panes of that tab, so the source of the split is usable. Other tabs stay stopped and dimmed until you select the project. Without the flag, creation selects the new tab or pane as usual.

```sh
macterm tab new --project api --no-focus --run "npm test"
macterm pane split --session "$MACTERM_SESSION" --no-focus --run "npm run dev"
```

The shell starts with no visit to the child, with or without `--run`. Creation returns before the shell is ready for more input. If you use `pane run`, wait for the shell prompt. Use `--json` to get the identity of the new tab or pane. Use `pane list --project P --tab T` to find the session of a new tab. `tab new` uses the **active project** by default. It does not use the project of the caller. If the two can be different, pass `--project`.

In an automation, select the app with `--socket`. When the running app is too old for `--no-focus`, the CLI refuses the command before it creates anything. The CLI asks the app for its protocol version first. It exits with an error and does not switch the view of the user in silence. Use the CLI that is in the app that you target. The `--help` of a newer CLI shows only that the flag exists in that CLI. It does not show that an older running app has it.

## Targeting a pane

Projects and tabs accept a **name**, a **UUID** or the **index** from the list output, counted from 1 (`3` or `tab:3`). A name that two items have gives an `ambiguous` error. The CLI never selects the first match in silence.

Pane commands find their target in this order:

1. `--session <name>`: the zmx session name. **It is stable across restarts.** Pane UUIDs change at every start, and session names do not. The CLI finds the session in the project that holds it, unless `--project` names a project.
2. `--pane <uuid|index>`.
3. `MACTERM_SESSION`: inside a pane. A bare `macterm pane split` therefore splits the pane that you are in. An explicit `--tab` turns this off.
4. In all other cases, the focused pane of the active tab.

The pane of a [desktop widget](/docs/desktop-widgets) belongs to no project. `pane dump`, `pane inspect`, `pane run` and `pane key` reach it with `--session` only. Inside the widget, they also reach it with `MACTERM_SESSION`.

`pane close` never uses `MACTERM_SESSION`. `pane focus --direction` treats the resolved target as the **origin**. It reports the pane that has the focus at the end.

## Typing into a pane

`pane run` types everything after `--` exactly as you wrote it, with the dashes:

```sh
macterm pane run --session macterm-api-8f327ce4a3f8 -- ls -la
```

Before `--`, its own flags are read at any place (`--no-submit`, the target selectors, `--socket` and `--json`). Words with no leading dash are typed. So `macterm pane run ls` and `macterm pane run clear --session macterm-api-8f327ce4a3f8` need no `--`. Any other word that starts with `-` before `--` is an error, and nothing is typed. For example, `macterm pane run ls -la` fails. It prints the same command with its text after `--`. `--help` before `--` prints help.

## Reading a pane

```console
$ macterm pane inspect
session             macterm-api-8f327ce4a3f8
grid                132×65
cell px             16×40
surface px          2176×2682
scrollback          360 total, 295 offset, 65 len
alt-screen          false
content scale       2.0
foreground          79497 (nvim src/main.rs)
process exited      false
needs confirm quit  false
```

`pane dump` prints the text of the viewport. `--scrollback` adds the full scrollback before it. It reads the own cells of the terminal, so it sees what a full-screen program draws.

Both commands need a **live surface**. A pane that you never showed returns `no_surface`. Select its tab one time.

> The C ABI of libghostty does not give the cursor position, and it has no direct alt-screen query. `alt-screen` here is a guess. It shows `-` until the surface sends its first scrollbar update.

## Skills for coding agents

`macterm skills` prints [Agent Skills](https://agentskills.io). These are `SKILL.md` files that Claude Code, Codex, OpenCode, Gemini CLI, Cursor and other agents load from a skills directory. They teach an agent this CLI:

- `macterm-panes`: run commands in panes and read their output.
- `macterm-workspace`: build a workspace that persists.
- `macterm-subagents`: run sub-agents in panes of their own.

There is no installer. The agent installs the skills. Give it this prompt:

```text
Run `macterm skills` and install each skill it prints into your skills directory as <name>/SKILL.md, exactly as printed. Then tell me what you installed and where.
```

`macterm skills <name>` prints one skill as it is. For example, `macterm skills macterm-panes > <skills dir>/macterm-panes/SKILL.md` installs it. `--list` shows the names. The text is inside the CLI, so it always matches your version. Install the skills again after you update Macterm.

## Environment

Macterm exports these variables into every shell that it starts:

| Variable | Meaning |
| --- | --- |
| `MACTERM_SOCKET` | The path of the control socket. This is a *hint* for discovery. The CLI falls back to well-known places. Only `--socket` pins the socket. |
| `MACTERM_SESSION` | The own session name of the pane, for self-targeting. |
| `PATH` | Macterm adds the `Resources/bin` of the bundle at the start. |

## Exit codes

stdout has output only when a command succeeds. All other text goes to stderr.

| Code | Meaning |
| --- | --- |
| `0` | Success. |
| `1` | The app returned an error. |
| `2` | The CLI could not reach a running Macterm. stderr lists every socket path that it tried. |

To make a script wait until the app is ready, use this loop:

```sh
until macterm status >/dev/null 2>&1; do sleep 0.2; done
```

## Scripting example

```sh title="dev-up.sh"
#!/bin/sh
set -e
mac=/Applications/Macterm.app/Contents/Resources/bin/macterm

# Wait for the app, then open the repo as a project.
until "$mac" status >/dev/null 2>&1; do sleep 0.2; done
"$mac" project create ~/dev/myapp --select

# A tab running the dev server, split for a test watcher.
"$mac" tab new --run "npm run dev"
"$mac" pane split --direction down --run "npm test -- --watch"
```

## Wire protocol

Any process of the same user can use the protocol directly. Use one request for each connection to `~/Library/Application Support/Macterm/control.sock`. Write one JSON line that ends with a newline. Close the write end of your connection. Read one line back.

```json title="request"
{"v":1,"id":"<any-string>","command":"pane.split","args":{"direction":"down","run":"btop"}}
```

`v` is the **minimum protocol version that the request needs**. It is not the version of the client. Ordinary commands use `1`. `--no-focus` sends `"v":2` with `"focus":false`. From v2, servers reject a request version that they do not support. Before dispatch, they check it. The v1 apps that shipped earlier ignore `v`. A direct client must therefore probe `status` first. It checks the **response** version before it sends newer fields. The CLI does this by itself and pins the command to the verified socket.

```json title="response"
{"v":2,"id":"<echoed>","ok":true,"data":{"panes":[{"id":"…","session":"macterm-api-1a2b3c4d5e6f","index":2}]}}
```

A failure looks like `{"ok":false,"error":{"code":"…","message":"…","action":"…"}}`. The codes are `starting`, `unknown_command`, `bad_request`, `not_found`, `ambiguous`, `busy`, `no_surface`, `unsupported_version` and `internal`. Both sides ignore unknown fields. When a field must not be ignored in silence, use the version checks above.

```sh
echo '{"v":1,"id":"x","command":"status"}' | nc -U ~/Library/Application\ Support/Macterm/control.sock
```

> The socket has mode `0600` in a directory with mode `0700`. The CLI refuses sockets that another user owns. Only the same user can use it. There is no token authentication.
