<!-- page:
slug: cli
title: The macterm CLI
nav: CLI
group: Automation
description: Drive the running app — projects, tabs, panes, sessions — from scripts and AI agents over a local socket.
-->

# The `macterm` CLI

Drives the **running app** — projects, tabs, panes, and their zmx sessions — over a local Unix socket.

Shells Macterm spawns already have `macterm` on their `PATH`:

```console
$ macterm status
Macterm 1.4.0 (pid 4242) — active project: api

$ macterm tab new --run "npm run dev"
tab:3  *  npm  1 pane

$ macterm grid 2x2 --run "tail -f log/dev.log"
```

From any other shell, use the bundle path or symlink it onto your `PATH`:

```sh
/Applications/Macterm.app/Contents/Resources/bin/macterm status
```

Every command takes `--json` for a scriptable payload and `--socket <path>` to target a specific instance. `--help` works at every level.

## Commands

The grammar is `macterm <noun> <verb> [options]`. A bare noun defaults to `list`.

| Command | Description |
|---|---|
| `status` | Version, pid, active project. Exits non-zero if no app is reachable. |
| `project list` | All projects with refs (`project:1`), active/loaded markers, tab counts. |
| `project create <path> [--name N] [--select]` | Add a project for a local directory or a [remote spec](/docs/remote-projects). **Not idempotent** — each run adds a distinct project. |
| `project select <name\|uuid\|index> [--window W]` | Make a project active. `pinned` selects the pinned-tabs workspace. |
| `project rename <project> <name>` | Rename a project. `Pinned` is reserved. |
| `project remove <project> [--force]` | Remove a project, killing its sessions. Returns `busy` when a pane runs a program, unless forced. Deletes no files. |
| `tab list [--project P]` | Tabs of a project (default: active). |
| `tab new [--project P] [--run CMD]` | New tab, becomes active. `--run` types CMD into the fresh shell. |
| `tab select <tab> [--window W]` | Activate a tab (`tab:3`, index, UUID, or exact title). |
| `tab move <tab> <slot>` | Reorder a tab. `slot` is its **final** 1-based position. |
| `tab rename <tab> [title] [--reset]` | Rename a tab, or restore the automatic title. |
| `tab close <tab> [--force]` | Close a tab, killing its sessions. Returns `busy` when a pane runs a program. Closing a pinned tab unloads it. |
| `window list` | Open windows in creation order (`window:1`). |
| `window new` | Open another window on the current project. |
| `window focus <window>` | Bring a window to the front. |
| `window close [--window W]` | Close a window. The last visible one hides instead. |
| `pane list [--project P] [--tab T]` | Panes with refs, session names, cwd, foreground process, and execution state. |
| `pane inspect [target]` | Snapshot of a pane's terminal core. Needs a live surface. |
| `pane dump [--scrollback] [target]` | Print a pane's terminal text. Text only, pipeline-friendly. |
| `pane split [--direction right\|left\|down\|up\|auto] [--run CMD] [target]` | Split a pane; the new pane inherits the cwd. `auto` picks the longer axis. |
| `pane mirror [--direction …] [target]` | Show the same session in a second pane. Focusing a mirror makes it the leader; the other dims. |
| `pane focus <target>` | Focus a pane: selects its tab, fronts the window, restores keyboard focus. |
| `pane focus --direction left\|down\|up\|right [target]` | Focus the nearest pane that way. A no-op at the outermost edge, not an error. |
| `pane close (--pane P \| --session S) [--force]` | Close a pane. Always requires an explicit target. |
| `pane run <command…> [--no-submit] [target]` | Type a command plus newline into a live pane. `--no-submit` leaves the text on the prompt. |
| `pane key <chord> [target]` | Send one key press (`a`, `ctrl+c`, `escape`, `up`). |
| `pane zoom [target]` | Toggle zoom on a pane. |
| `pane resize-split --axis horizontal\|vertical --ratio R [target]` | Set the ratio (0.15–0.85) of the nearest split on that axis. |
| `grid <RxC> [--run CMD] [target]` | Split a pane into an equal R×C grid (≤16 cells). `--run` spawns CMD in every new pane. |
| `session list` / `session info <name>` | zmx sessions with attached-pane mapping. |
| `session kill <name>` | Kill a session. An attached pane's shell exits. |
| `layout apply [--project P] [--force]` | Reconcile to the project's [layout file](/docs/declarative-layouts). Returns `busy` instead of closing panes. |
| `layout save [--project P]` | Write the live workspace to `~/.config/macterm/projects/<slug>.yaml`. |
| `tutor [project\|pinned]` | Print a short tutorial, with your own keybinds. Needs a running app. |
| `ssh <ssh args…>` | Run ssh with Macterm's terminal integration. The one verb that needs no running app. Flags mirror `ghostty +ssh`: `--terminfo=false`, `--forward-env=false`, `--cache=false`, `--verbose`. |

## Targeting a pane

Projects and tabs accept a **name**, a **UUID**, or the **1-based index** from list output (`3` or `tab:3`). A duplicate name is an `ambiguous` error, never a silent first match.

Pane verbs resolve their target in this order:

1. `--session <name>` — the zmx session name. **Restart-stable**: pane UUIDs regenerate every launch, session names don't. Found in whichever project holds it, unless `--project` names one.
2. `--pane <uuid|index>`.
3. `MACTERM_SESSION` — inside a pane, so a bare `macterm pane split` splits the pane you're in. An explicit `--tab` disables this.
4. Otherwise, the focused pane of the active tab.

`pane close` never uses the `MACTERM_SESSION` fallback. `pane focus --direction` treats the resolved target as the **origin**, and reports the pane that ended up focused.

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

`pane dump` prints the viewport's text; `--scrollback` prepends the full scrollback. It reads the terminal's own cells, so it sees what a full-screen program is drawing.

Both need a **live surface** — a never-shown pane returns `no_surface`. Select its tab once.

> Cursor position and a direct alt-screen query aren't available over libghostty's C ABI. `alt-screen` here is a heuristic, and reads `-` until the surface emits its first scrollbar update.

## Environment

Macterm exports into every spawned shell:

| Variable | Meaning |
| --- | --- |
| `MACTERM_SOCKET` | Control socket path. A discovery *hint* — the CLI falls back to well-known locations. Only `--socket` pins hard. |
| `MACTERM_SESSION` | The pane's own session name, for self-targeting. |
| `PATH` | Prepended with the bundle's `Resources/bin`. |

## Exit codes

stdout carries output only on success; everything else goes to stderr.

| Code | Meaning |
| --- | --- |
| `0` | Success. |
| `1` | The app returned an error. |
| `2` | No running Macterm could be reached (stderr lists every socket path tried). |

Gate a script on liveness:

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

Any same-user process can speak it directly. One request per connection to `~/Library/Application Support/Macterm/control.sock`: write one newline-terminated JSON line, half-close your write end, read one line back.

```json title="request"
{"v":1,"id":"<any-string>","command":"pane.split","args":{"direction":"down","run":"btop"}}
```

```json title="response"
{"v":1,"id":"<echoed>","ok":true,"data":{"panes":[{"id":"…","session":"macterm-api-1a2b3c4d5e6f","index":2}]}}
```

Failures are `{"ok":false,"error":{"code":"…","message":"…","action":"…"}}`. Codes: `starting`, `unknown_command`, `bad_request`, `not_found`, `ambiguous`, `busy`, `no_surface`, `internal`. Unknown fields are ignored on both sides.

```sh
echo '{"v":1,"id":"x","command":"status"}' | nc -U ~/Library/Application\ Support/Macterm/control.sock
```

> The socket is mode `0600` in a `0700` directory and the CLI refuses sockets owned by another user. Same-user only, no token auth.
