# Macterm Codebase Guide

A macOS terminal emulator built with SwiftUI and libghostty. Single-window app with project-based workspace management, split panes, and a quick terminal overlay.

## Build & Run

```bash
mise install          # Install tools (gh, swiftformat, swiftlint, xcodegen, xcbeautify)
mise run setup        # Download pre-built GhosttyKit.xcframework
mise run run          # Build and launch (debug)
mise run logs         # Stream live logs from the debug app (--release for release app)
mise run format       # Auto-fix formatting with swiftformat
mise run lint         # swiftlint
mise run test         # Run the test suite
mise run build        # Release build + DMG
mise run bench        # Release build + window-state resource benchmark
```

`format`, `lint`, and `test` show a spinner and print output only on failure. **Always pass `--verbose`** (e.g. `mise run test --verbose`) to stream the raw output.

Requires macOS 14+, Swift 6.0+. Liquid glass and a few chrome refinements are macOS 26 (Tahoe) features that degrade gracefully on older systems (gated behind `WindowAppearance.glassSupported` / `#available`). GhosttyKit is a pre-built xcframework from `thdxg/ghostty` (a fork that adds CI builds); no zig toolchain needed.

`GhosttyKit.xcframework` and the `Macterm/Resources/{ghostty,terminfo,…}` contents are gitignored artifacts downloaded by `mise run setup` — **every fresh checkout, including a git worktree, must run `mise run setup`** before it can build. Don't symlink them from another checkout: `setup.sh` only re-downloads when the artifact is _absent_ (presence check, not version check), so a symlinked copy silently goes stale. To refresh a stale artifact, delete it and re-run setup.

## Releasing & Updates

Auto-updates ship via [Sparkle](https://sparkle-project.org/) — daily background check, manual via **Macterm → Check for Updates…**. Updates verify an EdDSA signature, so no `xattr` workaround after first install. No telemetry.

Tag-pushed builds release via `.github/workflows/release.yml`, which needs repo secrets: `GH_PAT` (contents:read on `thdxg/ghostty`, downloads GhosttyKit), `SPARKLE_ED_PUBLIC_KEY` (baked into `Info.plist`), and `SPARKLE_ED_PRIVATE_KEY` (signs each DMG — **back it up; losing it means users can't auto-update to any further release**). The workflow appends an `<item>` to `appcast.xml` on `gh-pages` (served at `https://thdxg.github.io/macterm/appcast.xml`, the feed URL in `Info.plist`) along with a per-version notes page rendered from the GitHub Release body (`publish-appcast.sh`).

## Benchmarks

`.github/workflows/benchmark.yml` measures resource usage (CPU-time delta, RSS, and — best-effort via `powermetrics` — wakeups/s) across three window states: focused, open-but-unfocused, and minimized — each sampled twice: idle, then again as `workload-*` states after `$BENCH_WORKLOAD` (default 2) busy tabs are spawned through the bundled `macterm` CLI (`tab new --run` + `grid 2x2 --run`, a `/bin/sh` date loop per pane), so the numbers cover an app doing real terminal work. The idle state keys never changed, so their baseline history survives the workload's introduction; a baseline missing the `workload-*` states just shows no deltas for them (called out in the report footnote). Pushes to `main` upload a `benchmark-results` artifact that serves as the baseline; PR runs download the latest main baseline and post a comparison table to the job summary and a single updated-in-place PR comment. Runs land on different shared runners, so cross-run deltas are noisy — two defenses keep that noise from flagging. First, each state is sampled as the median of several short windows (`--samples`×`--seconds`, default 3×10s, same total wall-clock as the old single 30s window) so one co-scheduled CPU spike can't skew a state. Second, a delta is flagged only when it clears both ±25% _and_ the metric's absolute noise floor, and — for the CPU metrics — only when the _baseline itself_ is above a `min_baseline` (an idle app legitimately wanders 0.6–1.4% CPU on a shared runner, so a big relative swing off a sub-1.5% baseline is noise, not a regression). Guards live in `METRICS` in `benchmark.py`; a guarded-out delta still prints its raw % in the table, it just isn't flagged or labeled. Significant deltas add the `benchmark:regression` / `benchmark:improvement` PR label (removed again when a later push clears them) and the comment explains which metrics triggered it. The label + comment writes live in a separate `benchmark-report.yml` workflow triggered via `workflow_run`, not in `benchmark.yml` itself: a `pull_request` run from a fork gets a read-only `GITHUB_TOKEN` (the job's `permissions:` block is capped at read regardless of what it declares), so writing from there 403s. So `benchmark.yml` renders the report and uploads it as a `benchmark-report` artifact (report markdown, verdict JSON, and the PR number — the latter because `workflow_run.pull_requests` is empty for forked PRs), and `benchmark-report.yml` runs on completion in the base repo with a read/write token, downloads that artifact, and does the writes. The reporting workflow never checks out or executes fork code — it treats the artifact as pure data.

The harness (`scripts/benchmark.py`, invoked by `mise run bench`) launches the Release app under a throwaway `$HOME` (hermetic: no user ghostty config, fresh App Support) with `MACTERM_BENCHMARK=1`, which arms `BenchmarkControl` — Darwin-notification remote control (`notifyutil -p com.thdxg.macterm.bench.<cmd>`; commands: `open-project`, `activate`, `minimize`, `restore`). Darwin notifications and `open`-based activation need no TCC grants, which is what lets a headless CI runner script window states at all (AppleScript/synthetic keys would need an Accessibility grant). Benchmark mode also skips the notification-permission prompt (it would steal key focus mid-measurement) and doesn't start the Sparkle updater — a bench-built Release app carries the placeholder EdDSA key, so Sparkle's failed-start alert would otherwise block the launch run loop until someone clicks OK.

## Architecture

```
MactermApp (SwiftUI @main)
  └─ WindowGroup
       └─ MainWindow
            ├─ SidebarContent (List with native selection)
            └─ WorkspaceView
                 └─ SplitTreeView (recursive)
                      └─ TerminalPane
                           └─ TerminalSurface (NSViewRepresentable)
                                └─ GhosttyTerminalNSView (owned by Pane)
```

### Key Design: Pane-Owned NSView

**`GhosttyTerminalNSView` is owned by its `Pane` model, not by SwiftUI.** `TerminalSurface` is an `NSViewRepresentable` whose `makeNSView` returns `pane.ensureNSView()` — a cached instance living for the lifetime of the `Pane`. `dismantleNSView` is a no-op; the NSView dies only via an explicit `pane.destroySurface()`. This exists because ghostty surfaces are tightly coupled to their `NSView` + `CAMetalLayer` — if SwiftUI recreated the NSView on tree reshapes or tab switches, the surface would die.

### State Management

- **`AppState`** — single `@Observable`, passed via `.environment()`. All workspace/tab/pane mutations go through here. `WorkspaceStore` is injectable for tests.
- **`ProjectStore`** — global project list, persists independently.
- **`Workspace`** — per-project tab collection, keyed by project ID in `AppState.workspaces`.
- **`TerminalTab`** — owns a `SplitNode` tree and focused pane ID.
- **`SplitNode`** — recursive enum: `.pane(Pane)` or `.split(SplitBranch)`.

### Single Window Enforcement

The app blocks additional windows. `WindowGroup`'s `.newItem` command is replaced with a "Show Window" item (Cmd+N) that re-fronts the existing window. The close button hides (`orderOut`) instead of closing, preserving surfaces. Dock-icon reopen goes through an `NSWorkspace.didActivateApplicationNotification` observer in `AppDelegate.reopenIfNeeded()` — `applicationShouldHandleReopen` alone isn't reliable through `@NSApplicationDelegateAdaptor`, and AppKit reports `canBecomeMain = false` on ordered-out windows, so the filter walks `NSApp.windows` for any hidden non-panel window.

### Hotkey System

All keybinds are configurable via `HotkeyAction` + `HotkeyRegistry`. `KeyRouter` installs a single `NSEvent.addLocalMonitorForEvents` at launch and dispatches through the ordered `KeyResponder` chain in `Responders.swift`. `isAppShortcut` in `GhosttyTerminalNSView` lets registered app shortcuts pass through the terminal. Defaults live in `Hotkeys.swift`; user overrides in UserDefaults (`macterm.hotkey.<action_id>`).

### Tab Naming

A tab's auto-title is, by default, the pane's live **foreground process name** (`hx`, `btop`) — falling back to the login shell name (from `getpwuid`, not `$SHELL`) when idle, overridden by a user-set `customTitle`. `ProcessInspector.runningProcessName` reads the foreground pid's kernel `comm`. `AppState` polls panes adaptively (`PollCadence` + `refreshAllForegroundProcesses`, republishing only on change): 250ms during a ~5s burst after any poll event (tab switch, keystroke, OSC title, execution transition — all post `.terminalPollEvent`) or while a command runs frontmost, 1s when active-idle, 2s when inactive with a visible window, stopped when nothing is on screen (events resume it instantly; the quit dialog re-reads names one-shot since the poll may be paused). The status indicator's quiet-settle is skipped for occluded panes — their parked renderer emits no heartbeats, so silence proves nothing — with a fresh quiet window granted on the occluded→visible edge. OSC 0/2 titles are **provenance-gated** (`Pane.receiveReportedTitle`): the raw sequence can't distinguish a program naming its session (claude, ssh) from a shell titling its prompt (nushell, Starship emit the cwd), so the title string is adopted as `Pane.programTitle` only while the foreground process is a real program — not a shell — and is pinned to that pid; the poll expires it when the pid loses the foreground (`applyForegroundRefresh`), and prompt-time titles are discarded. `displayTitle` prefers `programTitle` over the process name; the quit dialog keeps the process-derived `processTitle`. Every OSC title arrival also triggers a process refresh (command boundary). Titles aren't persisted — always derived live.

**Remote panes** (#104) leave the local pipeline entirely — the local process table only knows the `ssh` client, so `ProcessInspector.foregroundPID(forPane:)` returns nil for them (which also makes layout `save` emit plain leaves and reconcile match them as idle). Their naming is two-tier: OSC 0/2 titles gated by the OSC 133 execution state instead of a pid (`Pane.receiveRemoteReportedTitle` — adopt while running, discard prompt churn, expire on the running→ended edge), plus `RemoteForegroundResolver`, one BatchMode ssh per host per ~3s (frontmost project only, overlapping probes dropped, failures freeze names) running the same session→leader→tpgid→comm pipeline as a portable POSIX script (`RemoteSpawn.foregroundProbeScript`). Idle fallback is the host name.

### Remote Projects (#104)

A project whose `path` is an scp-style `[user@]host:dir` spec (parsed by `ProjectPath`; created via the sidebar's New Project → Remote Machine sheet or a central project file). Each pane is a persistent zmx session **on that host**: the surface command is `ssh -t host 'sh -c '\''…cd dir && exec zmx attach <session>'\'''` (`RemoteSpawn.paneCommand`) with **no local zmx wrapper — nested zmx is broken upstream**, the remote daemon owns persistence. Quit kills the ssh clients → sessions detach and keep running (they survive local reboots); relaunch re-runs the same command against the snapshot's persisted `sessionName` and reattaches. The pane's ssh is interactive (no BatchMode) so password/2FA prompts render in the pane, and connection failures surface on ghostty's abnormal-exit screen — ssh's own stderr is the error UI. Background ops (kill, the naming probe) use `BatchMode=yes -o ConnectTimeout=5` so they can never hang on a prompt; teardown routes through `ZmxClient.killRemoteSession` (a local kill of a remote name would silently no-op).

**Design rule, earned the hard way: the spawn script may depend only on inputs Macterm controls — its own preamble and the project's config — never on the host's dotfiles.** The user's environment gets full effect in the right place instead: *inside* the zmx session, where their login shell starts normally (an `exec zsh` in `~/.profile` is legitimate user config for managed hosts — it just must never run in our plumbing). Do not reintroduce profile sourcing as an "improvement"; a regression test (`remote_scripts_never_source_profiles`) enforces this.

**Wire format (`RemoteSpawn`, hard-won against a real host):** every remote command ships as `sh -c '<single-quote-free script>'`. `sh -c`, NOT `sh -lc` — the login flag is unportable (older dash, common as `/bin/sh`, rejects `-l` and silently drops to an interactive shell that ignores the command). The single-quote-free script is the one form bash/zsh/fish/nu all tokenize identically before POSIX `sh` takes over. **PATH:** sshd runs commands with a bare non-interactive PATH, so the script appends a fallback dir list (`~/bin`, `~/.local/bin`, `~/.cargo/bin`, `/usr/local/bin`, `/opt/homebrew/bin`). Profiles (`/etc/profile`, `~/.profile`) are **deliberately never sourced, in any form** — they're arbitrary code in the pane's critical path, and every containment attempt leaked a pane-killer, each observed on a real or harness host: inline sourcing let a `~/.profile` ending in `exec zsh` hijack the script (fds→/dev/null: visible prompt via ZLE's /dev/tty, visible keystrokes via kernel pty echo, invisible output, no attach); a subshell harvest let the exec'd shell inherit the pane's tty stdin and block forever reading keystrokes; adding `</dev/null` still spun forever on a profile exec'ing a login shell that re-reads the same profile. The dir list covers where zmx actually lives; `zmxPath` covers everything else. **`zmxPath` escape hatch:** PATH resolution still can't cover every host (network-mounted home, exotic `/bin/sh`, PATH set only in a non-POSIX shell config), so a `Project.zmxPath` (optional, in the sheet + `projects.json` + `ProjectFile`) is used verbatim, bypassing PATH entirely and skipping the presence guard. **Failure visibility:** when zmx isn't found (PATH mode) or the `cd` fails, the script prints a `macterm:` diagnostic and drops to `${SHELL:-/bin/sh}` instead of exiting — a bare exit would fire `closeSurface` and vanish the pane with no clue why. **TERM falls back to `xterm-256color`** when the remote's terminfo doesn't know the forwarded `xterm-ghostty` (TUIs would refuse to start); hosts that ship the ghostty entry keep it, with full capabilities. (Verified un-confounded on a real host: zmx renders fine under `TERM=xterm-ghostty` — an earlier contrary finding was an artifact of the profile-hijack bug above.)

Constraints, all deliberate: zmx must be preinstalled on the host (set `zmxPath` if it's not on the non-interactive PATH); port/identity/ControlMaster/IPv6 come from `~/.ssh/config` aliases, never Macterm flags; the orphan reaper stays local-only (zero-client `macterm-*` sessions on a shared host legitimately belong to other machines); local-cwd features (Replace Project Path with Current Dir, live `run:`/`shell:` capture on Save Layout) are disabled for remote panes; declared layout `cwd`/`~` resolve remote-side as pure strings (`LayoutBuilder.resolveCwd`). Tested against loopback, a Docker Linux harness (nushell login shell, dash `/bin/sh`, zmx in `~/bin`, exec-ing `~/.profile` — Dockerfile preserved in PR #138's appendix), and a real CMU AFS host, which found four bugs the green environments couldn't.

## Layout

- `Macterm/App/` — `AppState`, `Preferences` (observable UserDefaults wrapper), `Hotkeys`/`KeyRouter`/`Responders`, `AppCommand`+`AppCommandActions`+`AppCommandMenu` (single source of truth for user-invokable actions — palette, menu bar, and Settings all render from `AppCommand.allCases`), `FocusRestoration` (retries `makeFirstResponder` across run-loop ticks), `Updater` (Sparkle), `AppInfo` (`appBundleID`, `appDisplayName`).
- `Macterm/Views/` — `MainWindow`, `Sidebar`, `SplitTreeView`, `TerminalPane`/`TerminalSurface`, `Terminal/GhosttyTerminalNSView` (core NSView: surface, keyboard, mouse, IME), `Terminal/SurfaceScrollView` (overlay scrollbar: surface nested in an `NSScrollView` with a spacer document view sized to scrollback), `QuickTerminal` (`NSPanel` + Carbon global hotkey), `SurfaceIncubator` (never-shown window giving off-screen tabs' panes a sized window so `createSurface()` succeeds early), `CommandPalette`, `QuitConfirmation`, `WindowAppearance` (opacity/blur/liquid glass, incl. private titlebar tree + CGS blur SPI), `TabSwitcherToolbarItem`.
- `Macterm/Ghostty/` — `GhosttyApp` (libghostty init/config/tick, resolves `GHOSTTY_RESOURCES_DIR`), `GhosttyCLI` (external CLI detection + `+ssh` probe), `GhosttyResources` (pure `GhosttyResourceResolver`), `GhosttyCallbacks`, `ThemeResolver` (`light:X,dark:Y` splits, #38), `Theme` (all UI colors).
- `Macterm/Palette/` — `PaletteEngine` (fuzzy scoring, sections, path mode) + `CommandSource`/`ProjectSource`/`DirectorySource`.
- `Macterm/Model/` — `SplitNode` (tree + `Pane`), `Workspace`/`TerminalTab`, `Project`, `TerminalSearchState`.
- `Macterm/Persistence/` — `WorkspacePersistence` (snapshots, `WorkspaceStore`), `ProjectStore`, `FileStorage`, `ProjectFile`/`ProjectFileStore` (central project files in `~/.config/macterm/projects/`), `LayoutBuilder`/`LayoutSerializer`/`LayoutReconciler` (declarative layouts), `LayoutFile` (deprecated in-repo `.macterm/layout.yaml`, seed-only).
- `Macterm/System/ProcessInspector.swift` — resolves a pane's foreground pid three ways: `runningCommand` (full argv via `KERN_PROCARGS2` → layout `run:`), `runningShell` (non-default shell's `exec_path` → layout `shell:`), `runningProcessName` (kernel `comm` → tab name).
- `Macterm/Config/` — `MactermConfig` (wrapper ghostty config files), `ShellIntegrationFeatures` (override merger, #75).
- `Macterm/Settings/SettingsView.swift` — preferences window.
- `Macterm/Control/` — control-socket plumbing for the bundled `macterm` CLI: `ControlProtocol` (wire types, shared source with the CLI target), `ControlSocketServer`, `ControlHandler`.
- `CLI/` — the `MactermCLI` target (`macterm` binary): ArgumentParser command tree, `ControlClient` (socket discovery + one-shot request), `Output` (human/`--json` renderers).

### Control CLI (`macterm`)

A bundled CLI (issue #107) controls the running app over a Unix socket at `<App Support>/control.sock` (per build flavor; `MACTERM_BENCHMARK_DATA_DIR` relocates it with the rest of app data). Full grammar + protocol reference in the docs site (`website/docs/pages/80-cli.md` → published at `/docs/cli`). Built as the `MactermCLI` tool target — `PRODUCT_NAME` is `macterm` but `PRODUCT_MODULE_NAME` must stay `MactermCLI` (a `macterm` module would collide case-insensitively with the app's `Macterm.swiftmodule` in the shared products dir). A post-build script copies it to `Contents/Resources/bin/macterm`; the app prepends that dir to `PATH` and exports `MACTERM_SOCKET` before any shell spawns, so `macterm` works inside every pane. Verbs: `status`; `project list/create/select`; `tab list/new/select/close`; `pane list/inspect/dump/split/focus/close/run/key/zoom/resize-split`; `grid RxC`; `session list/info/kill`; `layout apply/save`. New panes/tabs take `--run CMD` (spawn-time `initial_input`, the layout `run:` path); `pane run` types into an *existing* live shell via `GhosttyTerminalNSView.sendText` (the paste path — `ghostty_surface_key` with `.text`). `pane key <chord>` sends a single encoded keypress via `GhosttyTerminalNSView.sendKey` (`ghostty_surface_key` with a keycode+mods, no `.text`) — the control-byte/named-key counterpart (`ctrl+c`, `escape`, `up`, `ctrl+\`), reusing `HotkeyRegistry.parseShortcut`'s chord grammar. **This bypasses `keyDown` entirely** (that's how it emits raw control bytes), so any interception living in `keyDown` — e.g. the Ctrl-\ swallow guard — does *not* apply to `pane key`; the two key-input paths don't share a gate. `pane inspect`/`dump` are read-only introspection over libghostty's own state (`ghostty_surface_size`, the scrollbar snapshot, `ghostty_surface_read_text`) for debugging reflow/scrollback (#165); `zoom`/`resize-split` expose the zoom keybind + an absolute split-ratio setter as verbs (#166). `pane resize --cols --rows` is a **debug-only** in-place `set_size` for isolated reflow repro (#167) — gated `#if DEBUG` in both `ControlHandler`'s dispatch and the CLI, so a release app answers `unknown_command`. Every pane's env carries `MACTERM_SESSION` (its restart-stable session name) so a bare `macterm pane split` inside a pane self-targets; close verbs demand explicit targets and return a typed `busy` error instead of staging UI confirmation dialogs (headless callers can't click).

- **Wire protocol** (`ControlProtocol.swift`, compiled into both targets so the codec can't drift): one request per connection; newline-terminated JSON both ways; client half-closes after sending. Requests are `{v, id, command, args}` with `command` namespaced `noun.verb` (`pane.list`); responses echo `id` with `{ok, data}` or `{ok:false, error:{code, message, action?}}` — `action` is a human recovery hint. Errors use snake_case codes (`not_found`, `busy`, `no_surface`, `starting`…).
- **Server** (`ControlSocketServer`): dedicated thread polling a non-blocking listen fd (20ms) — never a blocking `accept()` on a queue shared with `stop()`, which would starve shutdown. Per-connection dispatch hops to `@MainActor`. Starts in `applicationDidFinishLaunching` (skipped under xctest); the handler attaches later in `installResponders` when AppState exists — early requests get a `starting` error. `FD_CLOEXEC` on the listen fd so spawned shells can't hold the socket past quit.
- **Handler** (`ControlHandler`): translate-and-delegate only — resolves selectors (name/UUID/1-based index for projects and tabs; conflicts and dupes are typed `ambiguous` errors) and calls the same `AppState`/`ProjectStore`/`ZmxClient` methods the UI uses. Reads zmx through `appState.zmx` so tests stub one seam.
- **CLI client**: discovery order `--socket` (hard pin) → `MACTERM_SOCKET` (hint only — falls through to the well-known release/debug paths when stale, avoiding cmux's pinned-env trap) → per-flavor App Support paths. Refuses sockets not owned by the current user; non-blocking connect with a 250ms poll so a dead socket never hangs. Safe-fail contract: stdout only on success; exit 0 ok / 1 app error / 2 unreachable.
- Security posture: same-user only, enforced by filesystem permissions (0600 socket, 0700 dir) — the same boundary zmx itself uses. No token auth by design; the request envelope leaves room for an `auth` field if that ever changes.

### Ghostty Config Pipeline

Macterm reads the user's `~/.config/ghostty/config` (path configurable in Settings). The user is the source of truth for every ghostty setting. `MactermConfig.regenerate()` writes two private files in App Support, and `GhosttyApp.loadConfig` loads `defaults → user's config → overrides` (libghostty does last-wins merge):

- **`macterm-defaults.conf`** — first-launch tasteful defaults; anything in the user's config overrides them.
- **`macterm-overrides.conf`** — keys Macterm must lock: `background-opacity = 0` / `background-blur = 0` (so `WindowAppearance` composites translucency itself without double-tinting), plus, when the external ghostty CLI is missing/too old, `GHOSTTY_BIN_DIR` and a `shell-integration-features` line disabling CLI-dependent features. That key can't be written bare — libghostty re-parses it from defaults on every occurrence, wiping the user's own flags — so `ShellIntegrationFeatures.overrideValue` re-emits the user's effective value with our `no-*` flags appended (#75). Because the override depends on the user's config content, `loadConfig` calls `regenerate()` before every load.

Macterm-specific UI state (window opacity/blur, quick terminal, hotkeys, auto-tile) lives in `Preferences` and never touches the ghostty config pipeline.

### Bundled Ghostty Resources (standalone operation)

Macterm bundles ghostty's runtime resources so it runs without a Ghostty.app install, **mirroring a real Ghostty.app layout**: `Contents/Resources/ghostty/{themes,shell-integration}` with the compiled terminfo DB at the _sibling_ `Contents/Resources/terminfo/`. `setup.sh` downloads the tarball from the `thdxg/ghostty` release; `project.yml` folder-references it into the bundle. `GhosttyApp.resolveResources()` points `GHOSTTY_RESOURCES_DIR` at `Contents/Resources/ghostty`, always resolving from our own candidates and ignoring any inherited env value (a stale one would shadow our complete bundle). Selection logic is the pure, tested `GhosttyResourceResolver`.

Two non-obvious terminfo facts (the regression behind #39/#40 — broken `TERM=xterm-ghostty` and key input):

- **Never set TERMINFO ourselves.** At shell spawn libghostty _unconditionally overwrites_ `TERMINFO` with `dirname(GHOSTTY_RESOURCES_DIR)/terminfo`, so the bundle layout must make that derivation land on the dir we ship — terminfo MUST be a sibling of `ghostty/`, never inside it. `BundledResourcesTests` asserts this invariant.
- **The terminfo tree uses the macOS hashed layout** — `terminfo/78/xterm-ghostty` (`x` = 0x78), not `terminfo/x/...`. It's a `tic -x` compiled tree shipped verbatim.

### Tests (`MactermTests/`)

One `XxxTests.swift` per production type, mirroring the source path. `@testable import Macterm` + `@MainActor` on test classes.

- Shared helpers in `MactermTests/Support/`: `TreeBuilder` DSL (`H(pane("a"), V(pane("b"), pane("c")))` → tree + name map) and `TreeRenderer` (inverse, for readable assertions).
- Tests needing `AppState`/`WorkspaceStore` inject a tempdir file — never touch `~/Library/Application Support/`.
- Tests run hosted inside the debug app, so `UserDefaults.standard` there is the developer's real debug-app domain. `Preferences.defaults` detects a test run (XCTest env vars) and resolves to a wiped `.tests` side suite instead, and everything that persists defaults (`Preferences.shared`, project recency, hotkey overrides) goes through it — so writes, including indirect ones like `AppState.activeProjectID`'s write-through, never leak out of the run (`PreferencesTests` guards this). Never use `UserDefaults.standard` directly in app code.
- UI (SwiftUI views, AppKit surfaces, libghostty bindings) is not unit-tested; coverage targets model + persistence + palette/hotkey logic and pure helpers.
- `BundledResourcesTests` is an artifact check: it asserts `Macterm/Resources/` ships what libghostty needs (#39/#40 guard) and `#require`-skips on a fresh checkout before setup has run.

## Conventions

### Code Style

- **SwiftFormat** + **SwiftLint** enforced. Run `mise run format`, `lint`, and `test` before committing.
- `@MainActor @Observable` on all state classes. No `@Published`/`ObservableObject`; inject via `@Environment(AppState.self)`, not `@EnvironmentObject`.

### Commit Conventions

- **Never add a `Co-Authored-By: Claude` trailer or any AI sign-off.** Commits are authored by the human committer only.
- Subject line focuses on the "why". Split logically independent changes into separate commits.
- **PRs merge via squash only** — make the PR title a good squash subject. When a PR conflicts, merge `main` into the branch; never rebase the branch onto `main`.

### UI Principles

- **Always use native SwiftUI/AppKit components.** Never mimic native behavior with custom implementations. If a native component has a limitation, accept it rather than building a workaround.
- All colors come from `MactermTheme` (derived from the ghostty theme config). No hardcoded colors.
- Minimum target is macOS 14; the liquid glass appearance is a macOS 26 (Tahoe) enhancement, gated so older systems fall back to native materials/blur. Gate any new Tahoe-only API behind `#available(macOS 26.0, *)` and, for user-facing controls, `WindowAppearance.glassSupported`.

### Terminal Surface Rules

- Never tear down the NSView from a SwiftUI path (`dismantleNSView` is a no-op by design).
- `pane.destroySurface()` kills the shell process — only call when a pane is permanently closed (AppState handles this after the pane leaves the tree).
- `createSurface()` needs a non-zero frame and a window; `TerminalSurface` defers creation until attached. A `Pane`'s `command`/`shell`/`env` (from a declarative layout) map to libghostty's `initial_input`/`command`/`env_vars`.
- The `closeSurface` callback fires asynchronously — guard against double-close.
- First-responder handoff after reshapes/tab switches must go through `FocusRestoration.restoreFocus(...)` — a bare `makeFirstResponder` races the NSView's window attachment.

### Persistence

- Workspaces → `~/Library/Application Support/Macterm/workspaces_v3.json`; projects → `projects.json`; wrapper configs (`macterm-defaults.conf`, `macterm-overrides.conf`) in the same directory. The directory name comes from `appDisplayName` (`CFBundleDisplayName`), so debug builds use `Macterm Debug/` — fully separate data per build, mirroring the bundle-ID split.
- `Pane` IDs are not preserved across restarts — restore creates fresh UUIDs. Session identity is separate: `Pane.sessionID`/`sessionName` persist in the snapshot (the name VERBATIM, never re-derived — its slug reflects the project at creation), so a restored pane reattaches its still-running zmx session.
- Project declarations are _authorable_ YAML files in `~/.config/macterm/projects/` (`ProjectFile`/`ProjectFileStore`), one per project: top-level `name:` (display only), `path:` (required — the identity), optional `tabs:` layout. Applied/saved on demand via `applyLayout`/`saveLayout`. JSON schema at `assets/project.schema.json` — keep it in sync when layout types change.
  - **Files and the runtime project list are decoupled.** `projects.json` stays the source of truth for which projects exist; a file matters only when a project with a matching path is added, first-opened, or has Apply/Save Layout invoked. Files are written on exactly two events — explicit "Save Layout" (creates/rewrites, realigning the filename to the current name slug) and the user's own editor. Nothing else (add/remove/rename/reorder/setPath) touches them, and the app never deletes one. No file watching: hand-edits made while running surface on next use (every read re-scans).
  - **Matching is by canonicalized `path:` inside the file, never by filename** (`ProjectPath.matches`; slugs are cosmetic, collisions get `_2` suffixes case-insensitively). `path:` is scp-style: absolute/`~` = local, `[user@]host:dir` = remote (parsed by `ProjectPath`, groundwork for remote projects #104 — not yet openable). Canonicalization expands `~` and normalizes `.`/`..` but resolves neither symlinks nor case; writes contract the home prefix back to `~` (`ProjectPath.homeContracted`) so files survive a dotfiles sync across usernames. Duplicate declarations: first in filename order wins; the rest are surfaced (palette subtitle via `paletteSubtitle`, post-save conflict alert), never deleted.
  - The directory is shared across debug/release builds (user config, like the ghostty config — unlike App Support) and resolves `$HOME`-env-first (`ProjectPath.currentHome`) so the benchmark's throwaway `$HOME` isolates it — `NSHomeDirectory()`/`expandingTildeInPath` resolve via the user record and silently ignore the env var.
  - On relaunch the workspace snapshot always wins — it carries live session identity, and force-applying a declared layout would destroy reattachable shells. A file only seeds a genuine first open (no snapshot; pure-spawn, never destructive) via `autoApplyLayoutOnFirstOpen`.
  - An unparseable file surfaces `LayoutFileError` in an alert (`AppState.pendingLayoutError`) and is never applied; the lenient `ProjectFileHeader` decode keeps a file with a broken `tabs:` matched to its project so the error shows on apply instead of the file silently unmatching. A file with no/empty `tabs:` is a bare declaration: nothing to apply, and the palette shows "Apply Layout" muted (`PaletteItem.isEnabled`) with the reason; an invalid file keeps the command enabled so invoking it surfaces the dialog.
  - `save` records a pane's `run:` as its **live** foreground command (`ghostty_surface_foreground_pid` → `ProcessInspector` argv via `KERN_PROCARGS2`) — an idle prompt saves no `run`. `shell:` is recorded only when the pane sits in a _non-default_ shell. `run` and `shell` are mutually exclusive on a leaf.
  - `apply` (`LayoutReconciler`) matches live panes to declared ones by that same live `(run, cwd)`; a pane that quit its declared command is respawned. A plain-shell leaf matches an idle pane positionally, but a declared `shell:` only reuses an idle pane running that shell (basename compare). The live-command/live-shell lookups are injected closures (default `ProcessInspector`), so the logic is unit-testable. There is no name-mismatch prompt: `name:` drift after a project rename is expected (only Save Layout rewrites it).
  - **Deprecated:** the in-repo `.macterm/layout.yaml` (`LayoutFile.load/exists`, schema `assets/layout.schema.json`) seeds the central file (`AppState.importLegacyLayout`) when no central file matches — on first open *and* on an explicit Apply Layout, because an existing project's restored snapshot suppresses first-open and would otherwise strand its legacy file for the whole deprecation window. Remove the whole path next release (#114).

### Adding a New Action

1. Add a case to `AppCommand` with title, category, and (if rebindable) linked `HotkeyAction`. The palette picks it up via `AppCommand.allCases`. **Titles must be Title Case** (macOS menu convention — minor words lowercase unless first/last, e.g. "Check for Update").
2. If keyboard-bindable, add the `HotkeyAction` case to `Hotkeys.swift` with its default shortcut.
3. Add a handler in the appropriate `KeyResponder` in `Responders.swift`. (`isAppShortcut` picks it up automatically.)
4. Add a test to `HotkeysTests.swift` if it introduces new parse/display behavior.

### Logging

`os.Logger` only — never `print()`/`NSLog()`. View with `mise run logs`. Every emitting file gets its own `private let logger = Logger(subsystem: appBundleID, category: "TypeName")` at the top (`appBundleID` keeps debug/release subsystems distinct). **Always mark interpolated values `.public`** — the default `.private` redacts them:

```swift
logger.info("selectProject: \(project.name, privacy: .public)")
```

### Adding a New Setting

Macterm-side settings flow through `Preferences` (UserDefaults); ghostty-shaped settings (theme, font, palette…) belong in the user's Ghostty config — don't add UI for them.

1. Add a property to `Preferences` with a `didSet` that writes to UserDefaults.
2. Only if Macterm breaks without forcing the value into libghostty: call `notifyConfigChanged()` from `didSet` and add the line to `MactermConfig.regenerate()`'s overrides. Most settings don't need this.
3. Add UI to `SettingsView.swift`, binding to `Preferences.shared.x`.

## Known Limitations

- **Quick-terminal sessions are ephemeral** — they die on quit (workspace panes persist via zmx and reattach on relaunch; local sessions don't survive reboot — the zmx daemon dies with the OS; remote sessions do, theirs doesn't).
- **Remote projects require zmx preinstalled on the host** — auto-detected via PATH (profiles + a fallback dir list); if that fails (network-mounted home, exotic `/bin/sh`, non-POSIX shell config), set the project's `zmxPath` to an absolute path. A missing binary surfaces a `macterm: zmx not found` diagnostic in the pane (not a silent close). No upload/install flow yet.
- **Remote orphan sessions aren't reaped** — the reaper is local-only by design (a shared host's detached `macterm-*` sessions may belong to another machine); crash leftovers on a remote are the user's to `zmx kill`.
- **Single window only** — multi-window would require a tmux-like daemon; out of scope.
- **Not code-signed with a Developer ID** — first launch needs `xattr -cr /Applications/Macterm.app` (or Homebrew install); Sparkle updates verify EdDSA after that.
- **Pane IDs not stable across restarts** — fresh views are created on restore.
