<!-- page:
slug: cli
title: The macterm CLI
nav: CLI
group: Automation
description: Drive the running app — projects, tabs, panes, sessions — from scripts and AI agents over a local socket.
-->

# The `macterm` CLI

Macterm bundles a control CLI that drives the **running app** — projects, tabs, panes, and their zmx sessions — over a local Unix socket. It's how scripts, AI agents, and other apps orchestrate the terminal: spawn a grid of panes, run a command in each, focus one, tear it down.

Shells that Macterm spawns already have `macterm` on their `PATH`, so inside any pane it just works:

```console
$ macterm status
Macterm 1.4.0 (pid 4242) — active project: api

$ macterm tab new --run "npm run dev"
tab:3  *  npm  1 pane

$ macterm grid 2x2 --run "tail -f log/dev.log"
$ macterm session list
macterm-api-8f327ce4a3f8  clients:1  pid:4310  attached-pane
```

From a shell Macterm *didn't* spawn, invoke it by bundle path (or symlink it onto your `PATH`):

```sh
/Applications/Macterm.app/Contents/Resources/bin/macterm status
```

Every command takes `--json` for a stable, scriptable payload instead of the human table, and `--socket <path>` to target a specific app instance. `--help` works at every level of the command tree.

## Commands

The grammar is `macterm <noun> <verb> [options]`. A bare noun defaults to its `list` verb, so `macterm project` is `macterm project list`.

| Command | Description |
|---|---|
| `status` | Liveness probe: version, pid, active project. Exits non-zero if no app is reachable. |
| `project list` | All projects with refs (`project:1`), active/loaded markers, tab counts. |
| `project create <path> [--name N] [--select]` | Add a project for a local directory. Idempotent by canonical path. `--select` activates it — and, on first open, applies a matching [layout file](/docs/declarative-layouts). |
| `project select <name\|uuid\|index>` | Make a project active. |
| `tab list [--project P]` | Tabs of a project (default: active project). |
| `tab new [--project P] [--run CMD]` | New tab, becomes active. `--run` types CMD into the fresh shell. |
| `tab select <tab>` | Activate a tab (`tab:3`, index, UUID, or exact title). |
| `tab close <tab> [--force]` | Close a tab, killing its panes' sessions. Refuses with `busy` when a pane runs a program, unless forced. |
| `pane list [--project P] [--tab T]` | Panes with refs, session names, cwd, foreground process, focus marker. |
| `pane inspect [target]` | Read-only snapshot of a pane's terminal core: grid, cell/surface pixels, scrollback totals, content scale, foreground pid + argv. Needs a live surface. |
| `pane dump [--scrollback] [target]` | Print a pane's terminal text — the viewport, or the full scrollback with `--scrollback`. Pipeline-friendly (text only). |
| `pane split [--direction right\|down\|auto] [--run CMD] [target]` | Split a pane; the new pane inherits the source's cwd. `auto` picks the longer on-screen axis. |
| `pane focus <target>` | Focus a pane: selects its tab, fronts the window, restores keyboard focus. |
| `pane close (--pane P \| --session S) [--force]` | Close a pane, killing its session. Always explicit — never defaults to "the pane you're in". |
| `pane run <command…> [target]` | Type a command (plus newline) into an **existing** live pane's shell. |
| `pane zoom [target]` | Toggle zoom on a pane (the tab renders only that pane while zoomed) — the same action as the zoom keybind. |
| `pane resize-split --axis horizontal\|vertical --ratio R [target]` | Set the ratio (0.15–0.85) of the nearest split of that axis around a pane. Absolute geometry, unlike the keybind's relative nudge. |
| `grid <RxC> [--run CMD] [target]` | Split a pane into an equal R×C grid (≤16 cells). `--run` spawns CMD in every **new** pane. |
| `session list` / `session info <name>` | zmx sessions as the daemon reports them, with attached-pane mapping. |
| `session kill <name>` | Kill a zmx session. If a live pane is attached, that pane's shell exits. |
| `layout apply [--project P] [--force]` | Reconcile the workspace to the project's [layout file](/docs/declarative-layouts). Returns `busy` instead of closing panes, unless forced. |
| `layout save [--project P]` | Write the live workspace to `~/.config/macterm/projects/<slug>.yaml`. |

> `pane run` types into a live shell — different from `--run`, which only applies to a pane at spawn time.

## Targeting a pane

Projects and tabs accept a **name/title**, a **UUID**, or the **1-based index** shown in list output (bare `3` or ref-style `tab:3`). A duplicate name is an `ambiguous` error, never a silent first-match.

Pane verbs (`split`, `focus`, `close`, `run`, `grid`) resolve their target in this order:

1. `--session <name>` — the zmx session name (`macterm-<slug>-<hex12>`). This is the **restart-stable** address: pane UUIDs regenerate every launch, session names persist verbatim.
2. `--pane <uuid|index>` — a pane UUID (searched project-wide), or its index within the tab scope.
3. `MACTERM_SESSION` — inside a pane, Macterm sets this to that pane's own session, so a bare `macterm pane split` splits *the pane you're in*. An explicit `--tab` disables this fallback.
4. Otherwise, the focused pane of the active tab.

`pane close` never uses the `MACTERM_SESSION` fallback — destroying "whatever pane I'm in" because no target was given is a footgun, so it always demands an explicit `--pane` or `--session`.

## Introspecting a pane

`pane inspect` and `pane dump` read libghostty's own live state — the fast path for debugging scrollback/reflow behavior without hand-instrumenting a build.

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

- **scrollback** is `total`/`offset`/`len` rows straight from libghostty's scrollbar signal. This is the field that made a resize/reflow scrollback bug diagnosable — a `total` that jumps to ~65k on a resize is the whole signal.
- **alt-screen** is a heuristic (`total ≤ len`), the same one the scrollbar uses; libghostty exposes no direct alt-screen query. It (and the scrollback fields) read `-` until the surface has emitted its first scrollbar update.
- **Cursor position is not reported** — the libghostty C ABI doesn't expose it. `inspect` surfaces exactly what the ABI provides.

`pane dump` prints the viewport's text; `--scrollback` prepends the full scrollback. It's the exact text libghostty would hand a "select all", so it round-trips cell contents faithfully:

```console
$ macterm pane dump --scrollback | wc -l
360
```

Both need a **live surface** (a never-shown pane returns `no_surface` — select its tab once to spawn it).

## Debug-only verbs

`pane resize --cols C --rows R [target]` drives a single, in-place `ghostty_surface_set_size` on a pane, bypassing the normal SwiftUI layout path — for reproducing a specific resize/reflow transition in isolation. It exists **only in debug builds**: it is absent from a release CLI's `--help`, and a release app rejects `pane.resize` as an unknown command. The live layout system reasserts the pane's real geometry on the next tick, so the verb drives the *transition* (and any reflow side effect, visible via `pane inspect`'s scrollback) rather than persisting a size.

## Environment

The app exports into every spawned shell:

- `MACTERM_SOCKET` — the control socket path. A discovery *hint*: if it doesn't answer (the app restarted since this shell spawned), the CLI falls back to the well-known locations. Only `--socket` pins hard.
- `MACTERM_SESSION` — the pane's own session name, for self-targeting.
- `PATH` — prepended with the bundle's `Resources/bin`, so `macterm` resolves.

## Exit codes

The CLI is pipeline-safe: **stdout carries output only on success**, everything else goes to stderr.

- `0` — success.
- `1` — the app returned an error (message plus a recovery hint on stderr, when it can suggest one).
- `2` — no running Macterm could be reached (stderr lists every socket path tried).

Scripts can gate on liveness:

```sh
until macterm status >/dev/null 2>&1; do sleep 0.2; done
```

## Scripting example

Spin up a project workspace from scratch, one pane per service:

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

The `macterm` binary is a thin client over a documented protocol — any same-user process can speak it directly. One request per connection to the socket at `~/Library/Application Support/Macterm/control.sock`: write one newline-terminated JSON line, half-close your write end, and read one line back.

```json title="request"
{"v":1,"id":"<any-string>","command":"pane.split","args":{"direction":"down","run":"btop"}}
```

```json title="response"
{"v":1,"id":"<echoed>","ok":true,"data":{"panes":[{"id":"…","session":"macterm-api-1a2b3c4d5e6f","index":2}]}}
```

Failures are `{"ok":false,"error":{"code":"…","message":"…","action":"…"}}` with snake_case codes: `starting`, `unknown_command`, `bad_request`, `not_found`, `ambiguous`, `busy`, `no_surface`, `internal`. Commands are `noun.verb`; unknown fields are ignored on both sides, so the protocol can grow without breaking clients. Debuggable by hand:

```sh
echo '{"v":1,"id":"x","command":"status"}' | nc -U ~/Library/Application\ Support/Macterm/control.sock
```

> The boundary is filesystem permissions, same-user only: the socket is mode `0600` in a `0700` directory, and the CLI refuses sockets owned by another user. There's no token auth by design — it's the same trust boundary the zmx session daemon already uses.
