# The `macterm` CLI

Macterm bundles a control CLI at `Macterm.app/Contents/Resources/bin/macterm`.
It drives the **running app** — projects, tabs, panes, zmx sessions — over a
local Unix socket, so AI agents, scripts, and other apps can orchestrate the
terminal (issue #107). Shells spawned by Macterm get it on `PATH`
automatically; from elsewhere, invoke it by bundle path or symlink it
somewhere on your `PATH`.

```console
$ macterm status
Macterm 1.4.0 (pid 4242) — active project: api

$ macterm tab new --run "npm run dev"
tab:3  *  npm  1 pane

$ macterm grid 2x2 --run "tail -f log/dev.log"
$ macterm pane run -- git pull
$ macterm session list
macterm-api-8f327ce4a3f8  clients:1  pid:4310  attached-pane
```

Every command takes `--json` (raw response payload, stable field names) and
`--socket <path>` (explicit socket override). `--help` works on every level
of the tree.

## Commands

| Command | Description |
|---|---|
| `status` | Liveness probe: version, pid, active project. |
| `project list` | All projects with refs (`project:1`), active/loaded markers, tab counts. |
| `project create <path> [--name N] [--select]` | Add a project for a local directory. Idempotent by canonical path. `--select` activates it — and, on first open, applies a matching [central project file](../assets/project.schema.json), spawning its declared tabs. |
| `project select <name\|uuid\|index>` | Make a project active. |
| `tab list [--project P]` | Tabs of a project (default: active project). |
| `tab new [--project P] [--run CMD]` | New tab, becomes active. `--run` types CMD into the fresh shell (layout `run:` semantics). |
| `tab select <tab>` | Activate a tab (`tab:3`, index, UUID, or exact title). |
| `tab close <tab> [--force]` | Close a tab — kills its panes' zmx sessions. Refuses with a `busy` error when a pane has a running program, unless forced. |
| `pane list [--project P] [--tab T]` | Panes with refs, session names, cwd, foreground process, focus marker. |
| `pane split [--direction right\|down\|auto] [--run CMD]` | Split a pane; the new pane inherits the source's cwd. |
| `pane focus` | Focus a pane: selects its tab, fronts the window, restores keyboard focus. |
| `pane close (--pane P \| --session S) [--force]` | Close a pane (kills its session). Always explicit — never defaults to "the pane you're in". |
| `pane run <command…>` | Type a command (plus newline) into a live pane's shell — works on an existing shell, unlike `--run` which only applies at spawn. |
| `grid <RxC> [--run CMD]` | Split a pane into an equal R×C grid (≤16 cells). `--run` spawns CMD in every **new** pane; the source pane keeps its shell. |
| `session list` / `session info <name>` | zmx sessions as the daemon reports them — including orphans from crashed/other instances — with attached-pane mapping. |
| `session kill <name>` | Kill a zmx session. An attached pane's shell exits; an orphan is reaped. |
| `layout apply [--project P] [--force]` | Reconcile the workspace to the project's central layout file. A reconcile that would close panes returns `busy` unless forced. |
| `layout save [--project P]` | Write the live workspace to `~/.config/macterm/projects/<slug>.yaml`. |

## Targeting

Projects and tabs accept a **name/title**, a **UUID**, or the **1-based
index** shown in list output (bare `3` or ref-style `tab:3`). Duplicate names
are an explicit `ambiguous` error, never a silent first-match.

Pane verbs resolve their target in this order:

1. `--session <name>` — the zmx session name (`macterm-<slug>-<hex12>`).
   This is the **restart-stable** address: pane UUIDs are regenerated on
   every launch, session names are persisted verbatim.
2. `--pane <uuid|index>` — a pane UUID (searched project-wide) or an index
   within the tab scope.
3. `MACTERM_SESSION` — inside a Macterm pane, the app injects this env var,
   so a bare `macterm pane split` splits *the pane you're running in*
   (self-targeting). An explicit `--tab` disables this fallback.
4. Otherwise: the focused pane of the active tab.

`--session` and `--pane` together are an error. `pane close` never uses the
env fallback — destroying "whatever pane I happen to be in" because no target
was given is a footgun; it demands an explicit target.

## Environment

The app exports into every spawned shell:

- `MACTERM_SOCKET` — the control socket path. A discovery *hint*, not a pin:
  if the hinted socket doesn't answer (the app restarted since this shell
  spawned), the CLI falls back to the well-known locations. Only `--socket`
  pins hard.
- `MACTERM_SESSION` — the pane's own session name, for self-targeting.
- `PATH` — prepended with the bundle's `Resources/bin`.

## Exit codes and output contract

- `0` — success. stdout carries the result (and *only* then).
- `1` — the app returned an error. stderr gets the message plus, when the
  app can suggest one, a recovery hint.
- `2` — no running Macterm reachable. stderr lists every socket path tried.

This safe-fail contract makes the CLI pipeline-safe: anything captured from
stdout is real output.

## Wire protocol (for non-CLI clients)

Any same-user process can speak the protocol directly; the CLI is just a
convenience. One request per connection to the Unix socket at
`~/Library/Application Support/Macterm[ Debug]/control.sock`:

1. Connect, write a single newline-terminated JSON line, then half-close
   your write end (`shutdown(fd, SHUT_WR)`):

   ```json
   {"v":1,"id":"<any-string>","command":"pane.split","args":{"direction":"down","run":"btop"}}
   ```

2. Read one newline-terminated JSON line back; the server closes:

   ```json
   {"v":1,"id":"<echoed>","ok":true,"data":{"panes":[{"id":"…","session":"macterm-api-1a2b3c4d5e6f","index":2,…}]}}
   ```

   Failures are `{"ok":false,"error":{"code":"busy","message":"…","action":"…"}}`
   with snake_case codes: `starting`, `unknown_command`, `bad_request`,
   `not_found`, `ambiguous`, `busy`, `no_surface`, `internal`.

Commands are `noun.verb` (`project.list`, `tab.new`, `pane.run`, `grid`,
`session.kill`, `layout.apply`); args is a flat object of optional fields
(see `Macterm/Control/ControlProtocol.swift`, the single source of truth
compiled into both the app and the CLI). Unknown fields are ignored on both
sides, so additive evolution never breaks a client. Debuggable by hand:
`echo '{"v":1,"id":"x","command":"status"}' | nc -U <socket>`.

## Security

The boundary is filesystem permissions, same-user only: the socket is mode
0600 in a 0700 directory, and the CLI refuses to connect to a socket owned by
another user. There is deliberately no token handshake — this matches the
posture of the zmx session daemon the panes already run under. If
mutually-untrusted local agents ever need scoping, the request envelope has
room for an `auth` field (Zentty's HMAC pane tokens are the model), without
breaking existing clients.

Sessions listed by `session list` may belong to *other* Macterm instances
(debug + release share the zmx daemon); such sessions show as `orphan` here
because no pane of *this* instance is bound to them. Killing one kills it for
its real owner too — check before you reap.
