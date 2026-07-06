<!-- page:
slug: cli
title: Command-line interface
nav: CLI
group: Automation
description: Drive a running Macterm from the shell — create projects, tabs, and panes, run commands, and script window layouts with the bundled macterm CLI.
-->

# Command-line interface

Macterm bundles a `macterm` CLI that controls the **running app** — projects, tabs, panes, and their zmx-backed sessions — over a local Unix socket. It's how AI agents, scripts, and other apps orchestrate the terminal: spawn a grid of panes, run a command in each, focus one, tear it down.

Shells that Macterm spawns already have `macterm` on their `PATH`, so inside any pane it just works:

```sh
macterm status
macterm tab new --run "npm run dev"
macterm grid 2x2 --run "tail -f log/dev.log"
```

From a shell Macterm *didn't* spawn, invoke it by bundle path (or symlink it onto your `PATH`):

```sh
/Applications/Macterm.app/Contents/Resources/bin/macterm status
```

Every command takes `--json` for a stable, scriptable payload instead of the human table, and `--socket <path>` to point at a specific app instance. `--help` works at every level of the command tree.

## Commands

The grammar is `macterm <noun> <verb> [options]`. Nouns default to a sensible list verb, so `macterm project` is `macterm project list`.

### status

```sh
macterm status
```

Prints the app version, process id, and active project — a one-line liveness probe. Exits non-zero if no app is reachable, so scripts can gate on it:

```sh
until macterm status >/dev/null 2>&1; do sleep 0.2; done
```

### project

```sh
macterm project list
macterm project create <path> [--name NAME] [--select]
macterm project select <name|uuid|index>
```

`create` adds a project for a local directory and is **idempotent** by canonical path — re-running it returns the existing project instead of erroring, so setup scripts can run unconditionally. With `--select` it also activates the project, which applies a matching [declarative layout](/docs/declarative-layouts) on first open. Remote (`host:path`) specifiers are rejected for now.

### tab

```sh
macterm tab list [--project P]
macterm tab new [--project P] [--run CMD]
macterm tab select <tab>
macterm tab close <tab> [--force]
```

`--run` types a command into the new tab's shell as it spawns. `close` kills the tab's panes and their sessions; if a pane is running a program it returns a `busy` error rather than killing it silently — pass `--force` to close anyway.

### pane

```sh
macterm pane list [--project P] [--tab T]
macterm pane split [--direction right|down|auto] [--run CMD] [target]
macterm pane focus <target>
macterm pane close (--pane P | --session S) [--force]
macterm pane run <command…> [target]
```

`split` inherits the source pane's working directory; `--direction auto` picks the longer on-screen axis. `run` types a command into an **existing** live pane (with a trailing newline), which is different from `--run` — that only applies to a pane at spawn time.

See **Targeting a pane** below for how `target` is resolved.

### grid

```sh
macterm grid <ROWS>x<COLS> [--run CMD] [target]
```

Splits a pane into an equal `ROWS`×`COLS` grid (up to 16 cells). With `--run`, every **new** pane spawns running `CMD`; the source pane keeps its shell. This is the fastest way to fan out work:

```sh
# a 2×2 grid, each new pane tailing the same log
macterm grid 2x2 --run "tail -f log/dev.log"
```

### session

```sh
macterm session list
macterm session info <name>
macterm session kill <name>
```

Lists the zmx sessions backing your panes — the persistent shells that survive a quit and reattach on relaunch. `kill` ends one; if a live pane is attached, that pane's shell exits.

> `session list` can include sessions from *other* Macterm instances that share the zmx daemon; those show as `orphan` because no pane of this instance is bound to them. Killing one ends it for its real owner too.

### layout

```sh
macterm layout apply [--project P] [--force]
macterm layout save [--project P]
```

`save` writes the live workspace to the project's [layout file](/docs/declarative-layouts); `apply` reconciles the workspace toward that file. An apply that would close panes returns `busy` unless you pass `--force`.

## Targeting a pane

Pane verbs (`split`, `focus`, `close`, `run`, `grid`) resolve their target in this order:

1. `--session <name>` — the zmx session name (`macterm-<slug>-<hex>`). This is the **restart-stable** address: pane UUIDs are regenerated every launch, session names are not.
2. `--pane <uuid|index>` — a pane UUID, or its `pane:N` index within the tab.
3. `MACTERM_SESSION` — inside a pane, Macterm sets this to that pane's own session, so a bare `macterm pane split` splits the pane you're in. Passing an explicit `--tab` disables this fallback.
4. Otherwise, the focused pane of the active tab.

Projects and tabs accept a name/title, a UUID, or the `1`-based index shown in list output (`tab:2`). An ambiguous name is a hard error, never a silent first match.

`pane close` is the one exception to the `MACTERM_SESSION` fallback: it always requires an explicit `--pane` or `--session`, so a bare invocation can't destroy the pane you're standing in by accident.

## Exit codes

The CLI is safe to pipe: **stdout carries output only on success**, everything else goes to stderr.

- `0` — success
- `1` — the app returned an error (with a message, and often a recovery hint, on stderr)
- `2` — no running Macterm could be reached

## Scripting example

Spin up a project workspace from scratch, one pane per service:

```sh title="dev-up.sh"
#!/bin/sh
set -e
mac=/Applications/Macterm.app/Contents/Resources/bin/macterm

# Wait for the app, then open the repo as a project.
until "$mac" status >/dev/null 2>&1; do sleep 0.2; done
"$mac" project create ~/dev/myapp --select

# A tab running the dev server, split for logs and a test watcher.
"$mac" tab new --run "npm run dev"
"$mac" pane split --direction down --run "npm test -- --watch"
```

## For non-CLI clients

The `macterm` binary is a thin client over a documented protocol — any same-user process can speak it directly. One request per connection to the socket at `~/Library/Application Support/Macterm/control.sock`: write one newline-terminated JSON line, half-close, and read one line back.

```json
{"v":1,"id":"1","command":"pane.split","args":{"direction":"down","run":"btop"}}
```

```json
{"v":1,"id":"1","ok":true,"data":{"panes":[{"session":"macterm-myapp-1a2b3c4d5e6f","index":2}]}}
```

Errors come back as `{"ok":false,"error":{"code":"busy","message":"…","action":"…"}}`. You can poke at it by hand:

```sh
echo '{"v":1,"id":"1","command":"status"}' | nc -U ~/Library/Application\ Support/Macterm/control.sock
```

Access is same-user only, enforced by filesystem permissions — the socket is `0600` in a `0700` directory, and the CLI refuses to connect to a socket owned by anyone else. There's no token auth by design; it's the same trust boundary the zmx session daemon already uses.
