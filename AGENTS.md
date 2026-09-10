# Macterm Codebase Guide

A macOS terminal emulator built with SwiftUI and libghostty: a project-based sidebar, split panes, persistent zmx sessions, remote (ssh) projects, a quick-terminal overlay, a control CLI, and — since #353 — any number of windows onto one shared model.

This file is the map: what exists, how it fits together, and the rules that were earned the hard way. Each rule is stated without its backstory; the reasoning lives in the doc comment on the symbol named, the PR that introduced it, and this file's own git history (the pre-2026-09 revision carried the full narratives). When you change a rule, change its doc comment too.

## Build & Run

```bash
mise install          # Install tools (gh, swiftformat, swiftlint, xcodegen, xcbeautify)
mise run setup        # Download pre-built GhosttyKit.xcframework + ghostty resources + zmx
mise run run          # Build and launch (debug)
mise run logs         # Stream live logs from the debug app (--release for release app)
mise run format       # Auto-fix formatting with swiftformat
mise run lint         # swiftlint
mise run test         # Run the unit test suite
mise run e2e          # Debug build + end-to-end suite against the real app
mise run bench        # Release build + resource benchmark
mise run build        # Release build + DMG
mise run install      # Copy the built app to /Applications
```

`format`, `lint`, `test`, `e2e` and `bench` show a spinner and print output only on failure. **Always pass `--verbose`** (`mise run test --verbose`) to stream the raw output.

Requires macOS 14+, Swift 6.0+. Liquid glass and some chrome refinements are macOS 26 (Tahoe) features gated behind `#available` / `WindowAppearance.glassSupported`.

### The terminal core

- **"libghostty" here means `ghostty-internal`**, which upstream marks "not for external use". `libghostty-vt` (the public library) has no surface API, so it is not a fallback. Treat every `ghostty_*` symbol as able to change without notice: pin, probe, and diff rather than assume.
- `GhosttyKit.xcframework`, `Macterm/Resources/{ghostty,terminfo}` and the bundled `zmx` are gitignored artifacts from the `thdxg/ghostty` and `thdxg/zmx` forks. **Every fresh checkout — including a git worktree — must run `mise run setup`.** Never symlink them from another checkout; setup's presence check would then never refresh them.
- Both fork releases are **pinned** (`GHOSTTYKIT_TAG`, `ZMX_TAG` in `scripts/setup.sh`) and recorded in gitignored `.ghosttykit-tag` / `.zmx-tag` stamps. Bumping a pin is its own reviewable commit; a weekly auto-PR (`.github/workflows/bump-ghosttykit.yml`, needs the `GH_PAT` secret so CI runs on it) does it for GhosttyKit and attaches an API review from `scripts/ghosttykit-api-diff.sh` — read the "renumbered enum constants" section of that report, since Swift imports enum constants by name and a mid-enum insert compiles silently.
- A pinned tag is **not immutable**: the fork has re-uploaded assets under the same tag. When a build behaves differently from an identical commit, compare `GhosttyKit.xcframework/*/Headers/ghostty.h` sizes before suspecting your own change. CI's DerivedData caches key on that header's hash for the same reason — don't collapse the restore/save split in `test.yml` or add a framework-agnostic `restore-keys` fallback.
- Setup requires the `GHOSTTY_ACTION_OUTPUT_ACTIVITY` ABI (the tab-activity heartbeat). Bisecting to before that requirement means installing a contemporary GhosttyKit by hand, not running setup.
- A stale-looking tree (stamp disagrees with reality) is cured with `rm -rf GhosttyKit.xcframework Macterm/Resources/terminfo && mise run setup`.

## Architecture

```
MactermApp (SwiftUI @main)
  └─ WindowGroup                       one scene, N windows (#353)
       └─ MainWindow  ── WindowState   per window: project, tab per project, sidebar, sheets
            ├─ SidebarContent          List with native selection
            └─ WorkspaceView
                 └─ SplitTreeView      recursive
                      └─ TerminalPane
                           └─ TerminalSurface (NSViewRepresentable)
                                └─ GhosttyTerminalNSView   owned by Pane, not SwiftUI
```

### Pane-owned NSView

`GhosttyTerminalNSView` is owned by its `Pane`. `TerminalSurface.makeNSView` returns `pane.ensureNSView()`, a cached instance living as long as the `Pane`; `dismantleNSView` is a no-op and the view dies only via `pane.destroySurface()`. Ghostty surfaces are welded to their `NSView` + `CAMetalLayer`, so a SwiftUI recreation on a tree reshape or tab switch would kill the surface. `SurfaceIncubator` is a permanently invisible window that gives off-screen panes a sized window so `createSurface()` can succeed early.

### State

- **`AppState`** — the single `@Observable` root, passed via `.environment()`. Every workspace/tab/pane/window mutation goes through it. `WorkspaceStore` is injectable for tests.
- **`ProjectStore`** — the project list (`projects.json`), persisted independently.
- **`Workspace`** — per-project tab collection, `AppState.workspaces[projectID]`. The pinned tabs are a sentinel workspace (see Pinned Tabs).
- **`TerminalTab`** — a `SplitNode` tree plus focused/zoomed pane IDs. **`SplitNode`** is `.pane(Pane)` or `.split(SplitBranch)`.
- **`WindowState`** (`Macterm/App/WindowState.swift`) — one per window: the project it shows, its tab per project (`activeTabIDs`), sidebar width/visibility, palette and sheet flags. Persisted as `WindowSnapshot`.
- **`Preferences`** — observable UserDefaults wrapper. Never touch `UserDefaults.standard` in app code; `Preferences.defaults` resolves to a wiped side suite under tests.

### Windows (#345, #353)

The rules that make multiple windows work over one model:

- **Registry keyed by `NSWindow`** (`AppState.windows`, a weak-keyed `NSMapTable`). SwiftUI instantiates a view and its `@State` more than once per real window, so the view cannot own identity; the first `WindowState` proposed for an `NSWindow` wins (`canonicalWindowState`). Register at NSWindow attachment, never in `onAppear`. Never stamp the SwiftUI window identifier.
- **One teardown entry**: `AppState.windowDidClose` clears every per-window table. A new per-window table must hang off it and be weak-keyed by the window (never by `ObjectIdentifier`, whose address gets reused).
- **App-wide values mirror the key window.** `AppState.activeProjectID`, `Workspace.activeTabID`, `sidebarVisible`, `isCommandPaletteVisible` etc. are pushed from/into the key window's `WindowState` by `noteKeyWindow`. Anything *rendered* per window must read `WindowState`, never the mirror. Something that happens *to* a project (notification click, CLI `pane focus`) goes through `revealProject`, which fronts a window already showing it.
- **A tab's real panes render in one window; other windows on that tab render a mirror.** `tabOwners` is sticky (settled by `reconcileWindowViews`); a non-owner gets a *shadow* tab of `Pane(mirroring:)` panes attached to the same zmx sessions, rebuilt when the real tab's `shapeSignature` changes. `WorkspaceView` maps a mirror's focus/zoom/split/click onto the real tab by tree position (`counterpartPaneID`). The pinned workspace has **no per-window tab selection** — every path that consults `activeTabIDs` skips the sentinel.
- **Session leadership.** Only one zmx client is leader (its size drives the pty); others render dimmed. `AppState.sessionLeaders` tracks it and an APC claim (`ZmxLeadership.claimSequence`, a wire contract with the zmx fork) tells zmx. Leadership follows the key window's tab whole (`claimLeadershipForKeyWindow`); records are re-asserted, never trusted; the claim is sent only when leadership moves, synchronously, recorded only if delivered, and never on focus for remote panes. A non-key window whose tab is entirely non-leader renders `MirroredTabNotice` instead of panes; the key window always renders its panes. First-responder restore after that goes through `FocusRestoration.restoreFocusWhenAttached`, which resolves the window from the pane's own view.
- **Closing and quitting.** Only the **last visible** terminal window hides on close (`AppDelegate.hidesInsteadOfClosing`); every other window really closes. Quit freezes the window list (`unregisterWindow` is a no-op under `AppTerminationState.isTerminating`), or each closing window would re-save a snapshot with one window fewer. `restoreWindows` gives the scene's own window the first saved entry and opens the rest via `applicationOpenUntitledFile`, fronting the saved key window last.
- **"Is this the terminal window?" is `AppDelegate.isTerminalWindowCandidate`**, not `!(window is NSPanel)`. It excludes marker subclasses (`QuickTerminalPanel`, `SurfaceIncubatorWindow`). Route any new auxiliary window through it; it is a heuristic used only before `didBecomeMain` has cached the real pointer.
- **A launch that doesn't front the app builds no window (#241)** — how macOS relaunches apps at login. `AppDelegate.repairMissingWindow` polls ~3s and, only if no candidate window exists, calls `applicationOpenUntitledFile` (activation alone does nothing). Gated on "no window at all" and debounced via `requestInitialWindow`, or one launch opens two windows.
- `AppDelegate.reopenIfNeeded` (Dock-click re-front) uses an `NSWorkspace.didActivateApplicationNotification` observer, since `applicationShouldHandleReopen` is unreliable through `@NSApplicationDelegateAdaptor`. Observers installed in `didFinishLaunching` miss launch-time window notifications — `didBecomeMain` can fire before it on Dock/Finder launches.

### Hotkeys

`HotkeyAction` + `HotkeyRegistry` hold the bindings (defaults in `Hotkeys.swift`, overrides at `macterm.hotkey.<action_id>`). `KeyRouter` installs one `NSEvent.addLocalMonitorForEvents` and dispatches through the ordered `KeyResponder` chain in `Responders.swift`; `isAppShortcut` in `GhosttyTerminalNSView` lets registered shortcuts pass the terminal.

**Passthrough (#209)**: a per-action opt-in (`.passthrough` suffix) hands the chord to the program in the focused pane when that program's name is in `Preferences.passthroughPrograms`. `KeybindPassthrough` owns the policy; both key paths (the responders *and* `isAppShortcut`) consult it; remote panes never yield. Inferring the condition (tty raw mode, "not a shell") was tried twice and failed — see the type's doc comment before re-attempting.

**Global keybinds**: a per-action opt-in (`.global` suffix, a Settings → Keymaps column beside passthrough) registers the chord as a Carbon `RegisterEventHotKey`, so it fires while another app is frontmost — Ghostty's `global:` prefix. `GlobalHotkeys` owns every registration in the process, the quick terminal's included (`HotkeyAction.isAlwaysGlobal`); `sync` reconciles it after each rebind and flag change, leaving an unchanged chord alone. Carbon, not a CGEvent tap: no Accessibility grant, and the system reports a chord it won't give us (`eventHotKeyExistsErr` → the row says so, rather than a chord that silently does nothing anywhere). **One owner:** Carbon consumes a registered hot key, so the local monitor never sees that keyDown — `KeyRouter` yields exactly the chords Carbon *holds* (`yieldsToCarbon`), which both states the no-double-fire rule and leaves a *refused* chord working as a plain local keybind. Consequences, both deliberate: a global chord always runs its app-level `AppCommand` (so it no longer reaches the quick-terminal responder's own splits), and global + passthrough on one action is refused rather than silently defeating passthrough. A fired chord fronts a window first (`AppDelegate.showWindow`) unless it is the quick-terminal toggle, whose panel is non-activating.

### Tab naming and activity

- A tab's auto-title is the foreground process name (`ProcessInspector.runningProcessName`, kernel `comm`), falling back to the login shell (from `getpwuid`), overridden by `customTitle`. `Preferences.autoNameTabs` off pins the static fallback in `Pane.displayTitle` only — polling keeps running for busy-close and execution tracking.
- `AppState` polls adaptively (`PollCadence` + `refreshAllForegroundProcesses`): 250ms burst after any `.terminalPollEvent`, 1s active-idle, 2s inactive, stopped when nothing is on screen.
- **The `GHOSTTY_ACTION_OUTPUT_ACTIVITY` heartbeat is the sole activity source** (it fires while occluded; the render-path scrollbar action does not). Completion edges (OSC 133;D, foreground transitions) rebase the row baseline so a fast command's late heartbeat never restarts it as activity. `TerminalExecutionTracker` holds the rules for when non-growing output counts as work (AI-agent foregrounds after a real Return).
- OSC 0/2 titles are **provenance-gated** (`Pane.receiveReportedTitle`): adopted as `programTitle` only while the foreground is a real program, pinned to that pid, expired when it loses the foreground. Prompt-time titles (nushell, Starship) are discarded. Titles are never persisted.
- **Remote panes** have no local pid. Their name comes from OSC titles gated by OSC 133 execution state, plus `RemoteForegroundResolver` — one BatchMode ssh per host per ~3s (frontmost project only) running the POSIX probe in `RemoteSpawn.foregroundProbeScript`, which also returns the host's own idle verdict and the foreground command line. Both pipelines publish one value, `Pane.foregroundSample`; policies like `ForegroundPolicy.needsConfirmClose` are pure functions over it. Every busy-close guard reads `Pane.needsConfirmClose`, never libghostty's `needsConfirmQuit` directly (for a remote pane that only sees the `ssh` client).
- The whole remote probe pipeline sits behind `Preferences.backgroundSSHConnections` (Settings → General → Remote Projects), the kill switch for Touch ID-gated hosts (#272). An auth-refused probe suspends that host's probes for the run.

### Tab switcher previews (#344)

Holding the Recent Tab chord shows `TabSwitcherOverlay`: one card per tab in the cycle (`AppState.tabCycleOrder`, bounded by `Preferences.recentTabCandidates`), each a mosaic of `PanePreview`s. Cards are **live**: `beginLivePreviews` sets `GhosttyTerminalNSView.rendersForPreview` so `syncOcclusion` reports the pane visible and libghostty wakes its renderer; sampled at 5 Hz until `commitTabCycle` runs `endLivePreviews` (every exit from a cycle goes through it, so no renderer stays awake). `PanePreview.frameID` skips re-sampling a pane whose IOSurface hasn't changed and the thumbnail is drawn through a no-copy provider — that is what keeps a hold at ~7% CPU instead of 30%. Hover never scrolls the rows (`HoverSelectionTracker`, shared with the palette). Don't reintroduce a foreground copy-poll or a text stand-in renderer; both were removed once off-screen panes could be sampled.

### Remote Projects (#104)

A project whose `path` is an scp-style `[user@]host:dir` (parsed by `ProjectPath`). Each pane is a persistent zmx session **on the host**: the surface command is `ssh -t host 'sh -c '\''…'\'''` (`RemoteSpawn.paneCommand`), no local zmx wrapper. Quit detaches; relaunch reattaches by persisted `sessionName`. The pane's ssh is interactive (prompts render in the pane); background ops use `BatchMode=yes -o ConnectTimeout=5`, exec PATH-resolved `ssh` via `/usr/bin/env` (same client as the pane), and kill through `ZmxClient.killRemoteSession`.

Rules for the spawn script, each earned against a real host:

- **Depend only on inputs Macterm controls** — never source `/etc/profile` or `~/.profile` in any form (a `~/.profile` ending in `exec zsh` hijacked the pane three different ways). The user's environment takes effect inside the zmx session, where their login shell starts normally. `remote_scripts_never_source_profiles` enforces this.
- Ship as `sh -c '<single-quote-free script>'` — `sh -c`, not `sh -lc` (dash rejects `-l`). Append a fallback PATH (`~/bin`, `~/.local/bin`, `~/.cargo/bin`, `/usr/local/bin`, `/opt/homebrew/bin`); `Project.zmxPath` bypasses PATH entirely.
- On failure (no zmx, `cd` fails) print a `macterm:` diagnostic and drop to `${SHELL:-/bin/sh}` — a bare exit fires `closeSurface` and the pane vanishes without a clue.
- **TERM is settled host-side and a resolvable TERM is never touched**, including one the user pinned coarser via `SetEnv`. Only an unresolvable TERM is replaced (`xterm-ghostty` if the host has it, else `xterm-256color`). The script exports `COLORTERM=truecolor` itself because TERM is the only variable ssh carries by a channel a server can't refuse.
- `RemoteTerminfo` installs our bundled `xterm-ghostty` entry (`infocmp -x | ssh … tic -x -`) off the critical path, gated on the user's own ghostty `ssh-terminfo` flag (default off upstream), never cached to disk, stderr logged on failure only.

**Dropped connections self-heal (#281).** `AppState.reconnectDroppedRemotePanes` respawns a dropped pane's surface in place (`destroySurface` then `requestSurfaceReattach`, never `killPersistentSession`). `AppState.handleProcessExit` classifies a remote exit by asking the host whether the session survived — **never by exit code** (always 0 on macOS). Triggers only (wake, activation, project selection) with `RemoteReconnectPolicy` backoff; no timer, no user-facing reconnect verb. `Pane.ensureNSView` passes `command` only on the first surface build so a respawn never retypes a layout `run:`.

**Remote orphans are reaped by ownership stamp.** `AppState.sweepOrphanSessions` (throttled per host) stamps `macterm.owner=<installationID>` on sessions our panes claim, lists, and kills only zero-client `macterm-*` sessions carrying **our** stamp (`ZmxReaper.orphans`). zmx labels are in-memory and settable only on live sessions, so a session orphaned before stamping is spared forever. `zmx ls --where` is silently unimplemented — never filter host-side. Both reapers skip entirely when `WorkspaceStore.loadFailed`.

### Pinned Tabs

Tabs belonging to no project, shown above the projects. They are a **sentinel workspace** (`workspaces[PinnedTabs.projectID]`, a fixed UUID that is not a `ProjectStore` row, so project iteration never sees it). Each is a `PinnedTabRecord`: a durable declaration (`LayoutTab`) plus, while loaded, a live `TerminalTab`. All the logic is in `AppState+PinnedTabs.swift`.

- Pin/Unpin are `moveTab`s, never kills. A tab born in the pinned workspace is pinned by `syncPinnedRecordsWithWorkspace`.
- **Closing a pinned tab is an unload**, never a removal: sessions end, the record stays as a dimmed row, relaunch eager-starts it again. Unpin is the removal path. The same unload happens when a tab's own sessions die (`paneProcessExited`). `unloadProject` uses the same dimmed-row treatment via `AppState.unloadedProjectIDs` (in-memory only; cleared in `activeProjectID`'s `didSet`).
- Persistence is two layers: live state in `workspaces_v3.json`'s `pinned` section, and the declaration in `~/.config/macterm/projects/pinned.yaml` — the **one auto-written file** in that directory, a `ProjectFile` whose reserved `path: <pinned>` is the marker, with no per-entry ids (matched back by name → exact layout → position, `PinnedLayoutMatcher`). `AppState` tracks its own last write and absorbs external edits before every write; an unparseable file suspends auto-writes with an alert. An absent/empty file means "no input", never "remove everything".
- At launch every record materializes (`materializeRestoredPinnedTabs` asks `zmx ls` which sessions survived; dead ones respawn from the declaration). The declaration refreshes at pin time, on pinned foreground changes (debounced), and at quit — never at unload.
- Sidebar drag: pinned rows and tab lists share one ForEach-level `.dropDestination` that drives the native insertion line; rows carry no destinations of their own (a row-level target kills the line and swallows clicks). `PinTabDropZone` above the List is what makes the first pin possible by drag. `--project pinned` addresses the workspace over the CLI.

### First-run seed

`FirstRunSeed` (pure) + `AppState.seedFirstRunIfNeeded` seed a fresh install with one project (the home directory) and one pinned "Welcome" tab, each running `macterm tutor <topic>` as its `run:`. It runs after `restoreSelection`; `Preferences.hasSeededFirstRun` is written on the first launch that can answer, seeded or not, except `.postpone` on `WorkspaceStore.loadFailed`. Off (postponed, not skipped) under `MACTERM_BENCHMARK=1`, because the harnesses look like fresh installs and do not isolate the defaults domain. The seeded `run:` is bare words so it tokenizes identically in every login shell.

### Project color tags

`Project.colorName` tints glyphs the row already draws (project icon, tab-row icons, including agent logos and status glyphs). **No stripes; no glyph means no tag; no titlebar indicator** — each alternative was tried and rejected. Colors are fixed system colors (`MactermTheme.color(for:)`), deliberately not derived from the ghostty palette. The picker is `.pickerStyle(.palette)` (`ProjectColorMenu`) — the only menu form that renders. Stored as a String so an unknown value degrades to untagged. `iconStyle` wraps both arms in `AnyShapeStyle`, because `tagColor ?? .secondary` silently coerces to `Color.secondary` and restyles every untagged row. `Preferences.autoAssignProjectColors` (default off) is read at creation only, via an injectable closure on `ProjectStore`.

### Finder Services

**Services → New Macterm Project Here** is an `NSServices` plist entry plus `FinderServiceProvider` (`Macterm/App/FinderServices.swift`). The plist `NSMessage` and the `@objc` selector are an unchecked runtime contract — `FinderServicesTests` reads the plist back. A request can arrive before the app has restored state, so the provider queues until `attach` and then defers through `AppState.performWhenRestored` — the hook any launch-time external request should use.

**Opening a folder WITH Macterm** — Finder's Open With, a Dock-icon drop, `open -a Macterm <dir>` — is that same gesture by another route: one `CFBundleDocumentTypes` entry (`public.directory`, `LSHandlerRank: Alternate`, so Finder stays a folder's default opener) and **no file types**, with `AppDelegate.application(_:open:)` handing the folders to `FinderServiceProvider.open(paths:)` — so a cold launch reuses the queue-and-defer above. A folder is always a **new** project, never a tab. Unlike the service, a file is logged and dropped rather than resolved to its parent (`FolderOpenRequest`, `Macterm/App/OpenFolder.swift`): the service is offered *on* the file the user right-clicked, whereas a file here means `open -a` was pointed at something the plist never declared. `OpenFolderTests` reads the plist back for the folders-only contract.

**SwiftUI answers that same event by opening a second window, and the scene's `handlesExternalEvents(matching:)` is what stops it.** Left alone, an open-documents event gets a new `WindowGroup` window on top of the project the delegate just selected — two windows on one tab, a dimmed mirror in front and `MirroredTabNotice` behind — and it happens with our delegate method removed too, so it is SwiftUI's handling, not ours. Macterm emits no external events of its own (no URL scheme, no Handoff), so the group declares a condition nothing ever matches. The set must be **non-empty**: `[]` means "handles no external events at all" and also silences `applicationOpenUntitledFile`, which is the only call that reliably builds a `WindowGroup` window — New Window, `window new` and #241's repair were all measured dead under `[]` and alive under a never-matching condition.

### Dock menu

Right-clicking the Dock tile offers **New Window**, **New Tab**, **New Project…**, **Toggle Quick Terminal** — Ghostty's set, built by `AppDelegate.applicationDockMenu` (`Macterm/App/DockMenu.swift`; `@NSApplicationDelegateAdaptor` does forward this one, verified live). Items are `AppCommand`s run through `AppCommand.action(in:)`, so the Dock is a fourth renderer of that list rather than a second set of handlers; the menu is rebuilt per right-click with `autoenablesItems` off (enabled ⇔ non-nil action), and is nil until `MainWindow` hands the delegate its state objects. What the Dock adds is `DockMenu.Preparation`: a pick arrives from outside the app and does not activate it, so New Tab / New Project… call `showWindow()` first (the hidden last window, or the #241 no-window state), New Window activates and lets the command make its own, and Toggle Quick Terminal prepares **nothing** — the panel is non-activating by design. The action is resolved *after* preparing, since fronting a window is what makes `activeProjectID` the right project.

### Control CLI (`macterm`)

A bundled CLI (target `MactermCLI`, `PRODUCT_MODULE_NAME` must stay `MactermCLI`) controls the app over `<App Support>/control.sock`. It is copied to `Contents/Resources/bin/macterm`; every pane gets it on `PATH` plus `MACTERM_SOCKET` and `MACTERM_SESSION`. Full grammar in `website/docs/pages/80-cli.md`. Verbs: `status`; `project list/create/select/rename/remove`; `tab list/new/select/move/rename/close/merge`; `pane list/inspect/dump/split/focus/close/run/key/zoom/resize-split/mirror`; `grid RxC`; `session list/info/kill`; `window list/new/focus/close`; `layout apply/save`; `tutor`; `ssh` (offline — ghostty's `+ssh` natively via `SSHWrapper`).

- **Wire protocol** (`ControlProtocol.swift`, compiled into both targets): one newline-terminated JSON request per connection, `{v, id, command, args}` with `noun.verb` commands; responses `{ok, data}` or `{ok:false, error:{code, message, action?}}` with snake_case codes (`not_found`, `busy`, `no_surface`, `starting`, `ambiguous`).
- **Server** (`ControlSocketServer`): dedicated thread polling a non-blocking listen fd; per-connection dispatch hops to `@MainActor`; starts in `applicationDidFinishLaunching`, handler attaches in `installResponders` (early requests get `starting`). 0600 socket in a 0700 dir, same-user only.
- **Handler** (`ControlHandler`): translate-and-delegate only — resolve selectors (name/UUID/1-based index), call the same `AppState`/`ProjectStore`/`ZmxClient` methods the UI uses. Close verbs return a typed `busy` error rather than staging dialogs.
- **Client**: discovery `--socket` → `MACTERM_SOCKET` (hint, falls through when stale) → per-flavor App Support paths. stdout only on success; exit 0 ok / 1 app error / 2 unreachable. **Targeting trap**: an unpinned `--socket` from a debug harness can hit the developer's live app; `pane run --help` types into their focused pane.
- `pane run` types via the paste path (`sendText`; `--no-submit` withholds the newline and keeps submission evidence armed). `pane key <chord>` rides the key-encoding path (`sendKey`) and **bypasses `keyDown`**, so `keyDown` interceptions don't apply; a bare printable must carry `.text` or it encodes to nothing. `pane resize` is `#if DEBUG` only.

### Ghostty config pipeline

Automatic mode delegates the user layer to `ghostty_config_load_default_files`; Settings can append custom files. `GhosttyApp.loadConfig` loads `macterm-defaults.conf → user files → macterm-overrides.conf` (last wins), regenerating both private files (`MactermConfig.regenerate()`) before every load because the overrides depend on the user's content. `GhosttyConfigSource` is the raw-text seam for keys the C API can't expose.

Overrides Macterm must lock: `background-default-transparent = true` (fork patch — the renderer skips the default background so `WindowAppearance` composites translucency itself), `background-opacity = <Preferences.windowOpacity>` (the real value, so the user's `background-opacity-cells` works), `background-blur = 0` (Macterm calls the CGS blur SPI), `env = GHOSTTY_BIN_DIR=<bundle>/Contents/Resources/ssh-bridge` (holds our `ghostty` shim relaying `+ssh` to `macterm ssh`; kept out of any dir on the pane PATH), and `shell-integration-features` re-emitted with the user's flags plus `no-path` (`ShellIntegrationFeatures.overrideValue`, #75 — the key can't be written bare). Macterm UI state lives in `Preferences` and never touches this pipeline.

**Custom app icon**: `macos-icon = custom` + `macos-custom-icon` is honored with Ghostty's semantics. `GhosttyApp.applyAppIcon` runs after every load and reload, reads both keys off the *loaded* config (so a `config-file` include counts) through `configCString` — libghostty's C getter hands enums back as their tag name and `?[:0]const u8` as a bare C string, not a `ghostty_string_s`, which is why that getter is distinct from `configString` — and passes them to the pure `GhosttyAppIcon.resolve` (`.bundled` / `.custom(URL)`; no path means Ghostty's `~/.config/ghostty/Ghostty.icns`, a path still relative after `~` expansion is invalid since a GUI app's cwd is unpredictable). The one AppKit write is `AppIconPresenter.apply`, which sets `NSApp.applicationIconImage` and assigns nil — that is what restores the bundle icon — for a missing, unreadable or undecodable file. Every other `macos-icon` value is Ghostty-brand artwork we don't ship; Ghostty's Dock-tile plugin is deliberately not mirrored. Hermetic caveat: `loadConfig` disables the user layer under `MACTERM_BENCHMARK=1`, so verify with a throwaway `HOME`/`XDG_CONFIG_HOME`/`ZMX_DIR` plus `MACTERM_BENCHMARK_DATA_DIR` and **no** `MACTERM_BENCHMARK`.
**`macos-hidden`**: ghostty's `never`/`always` maps to `.regular`/`.accessory` through `MacosHidden` (a pure, tested function; the raw values are ghostty's own tag names, so renaming a case is a wire break). `AppDelegate.applyActivationPolicy` applies it after `GhosttyApp.shared` at launch and again on `.mactermConfigDidChange`, skipping AppKit when the policy already agrees — that is what makes the over-firing observer safe. Read it as an **enum** (`configEnum`, a bare `[*:0]const u8`), never through `configString`, whose `ghostty_string_s` leaves `len` at 0 — the reason `GhosttyColorSpace` went to raw text. Accessory mode is deliberately narrower than Ghostty.app's, which builds no window: Macterm still builds one, because `MainWindow.onAppear` installs the responders and attaches the control handler. Every explicit window request (`window new`/`window focus`, `revealProject`) calls `MacosHidden.activateForWindowRequest`, which forces activation with `ignoringOtherApps: true` — plain `activate()` and a cross-process activate were both measured **refused** by cooperative activation, silently. An accessory app has no menu bar, so Settings, Quit, About and Check for Updates lose their only route; keybindings are unaffected (`KeyRouter`, not the menu bar).

**Process locale (#370)**: `ghostty_init` calls `setlocale(LC_ALL, "")`, and under any comma-decimal locale SwiftUI's toolbar glyph rendering asserts inside CoreUI on macOS 27 (SIGTRAP, nothing on stderr). `ProcessLocale.pinNumericToC()` runs right after `ghostty_init` and touches only `LC_NUMERIC`. Reproduce with `LANG` unset (a Dock launch); `OS_ACTIVITY_DT_MODE=enable ACTIVITY_LOG_STDERR=1` surfaces the assertion text.

### Bundled ghostty resources

The bundle mirrors Ghostty.app: `Contents/Resources/ghostty/{themes,shell-integration}` with the compiled terminfo at the **sibling** `Contents/Resources/terminfo/`. `GhosttyApp.resolveResources()` sets `GHOSTTY_RESOURCES_DIR` from our own candidates, ignoring any inherited value. **Never set `TERMINFO` ourselves** — libghostty overwrites it with `dirname(GHOSTTY_RESOURCES_DIR)/terminfo`, so terminfo must be a sibling of `ghostty/` (#39/#40). The tree uses the macOS hashed layout (`terminfo/78/xterm-ghostty`). `BundledResourcesTests` asserts all of this and skips before setup has run.

### Adaptive terminal background

`AdaptiveTerminalBackground` infers a TUI's background from libghostty's BGRA8 IOSurface (fails closed if the format changes) or takes OSC 11 directly. Rules: the alpha floor derives from the window opacity (`minimumPaintedAlpha`) because painted cells arrive premultiplied at `background-opacity`; a translucent color gets no pane fill and has the window tint **cut out from under it** (`TintCutout`, edge-walked by alpha via `paintedUnitBounds`), so the tint lives in a maskable view, never `NSWindow.backgroundColor` or `NSGlassEffectView.tintColor`; the tint does not depend on key status; colors are read in the renderer's color space (`GhosttyColorSpace`). `AdaptiveTerminalInferenceGate` freezes inference while `ghostty_surface_has_selection` is true and protects a confirmed color from repaints with no output heartbeat within 1.5s (adoption only, never clearing). The winning color must also span 0.80 of the sampled grid **per axis** (`minimumBackgroundExtent`), which is what keeps a slide or image from retinting the window. The quick terminal is outside the window-wide tint.

## Layout

- `Macterm/App/` — `AppState` (+ `AppState+PinnedTabs`, `AppState+FirstRun`), `WindowState`, `Preferences`, `Hotkeys`/`KeyRouter`/`Responders`/`KeybindPassthrough`, `AppCommand`+`AppCommandActions`+`AppCommandMenu` (single source of truth for user-invokable actions — palette, menus and Settings render from `AppCommand.allCases`), `FocusRestoration`, `Updater` (Sparkle), `AppInfo`, `FirstRunSeed`, `Tutorial`, `FinderServices`+`OpenFolder`, `DockMenu`, `BenchmarkControl`, `ExceptionReporting`, `EnvironmentSetup`, `Notifications`/`NotificationHandler`, `PollCadence`, `RecencyStack`, `TabIndexChord`.
- `Macterm/Views/` — `MainWindow`, `Sidebar` (+ `SidebarOverlay`, `SidebarPresentationState`), `SplitTreeView`, `TerminalPane`/`TerminalSurface`, `PaneDragDrop`, `CommandPalette`, `TabSwitcherOverlay`/`TabSwitcherToolbarItem`, `QuickTerminal` (`NSPanel` + Carbon global hotkey), `SurfaceIncubator`, `QuitConfirmation`, `NewRemoteProjectSheet`, `ProjectColorMenu`, `SearchBar`, `Toast`, `WindowAppearance` (opacity/blur/liquid glass, private titlebar tree, CGS blur SPI). `Terminal/`: `GhosttyTerminalNSView` (surface, keyboard, mouse, IME), `SurfaceScrollView` (overlay scrollbar), `PanePreview`, `SearchTickOverlay`, `TerminalCommandSubmission`.
- `Macterm/Ghostty/` — `GhosttyApp` (init/config/tick), `GhosttyCallbacks`, `GhosttyResources`, `ThemeResolver` (`light:X,dark:Y` splits, #38), `Theme` (all UI colors), `AdaptiveTerminalBackground`/`AdaptiveTerminalChrome`.
- `Macterm/Model/` — `SplitNode` + `Pane`, `Workspace`/`TerminalTab`, `Project`, `ProjectPath`, `ProjectColor`, `PinnedTabs`, `ForegroundSample`, `TerminalExecutionTracker`, `TerminalSearchState`, `AgentIcon`.
- `Macterm/Persistence/` — `WorkspacePersistence` (snapshots, `WorkspaceStore`), `ProjectStore`, `FileStorage`, `ProjectFile`/`ProjectFileStore` (`~/.config/macterm/projects/`), `LayoutBuilder`/`LayoutSerializer`/`LayoutReconciler`, `LayoutFile` (in-memory only), `PinnedLayoutStore`.
- `Macterm/System/` — `ProcessInspector` (foreground pid → `runningCommand`/`runningShell`/`runningProcessName`), `ZmxClient`, `ZmxForegroundResolver`, `RemoteSpawn`, `RemoteForegroundResolver`, `RemoteReconnectPolicy`, `RemoteTerminfo`, `SSHWrapper` (shared with the CLI target), `ProcessLocale`, `FullDiskAccess`, `SecureInput`, `ObjCExceptionCatcher` (`@try/@catch` trampoline — AppKit raises ObjC exceptions Swift can't catch).
- `Macterm/Config/` — `MactermConfig`, `GhosttyConfigSource`, `ShellIntegrationFeatures`, `GhosttyColorSpace`, `MacosHidden`.
- `Macterm/Settings/` — `SettingsView` (panes + `PinnedSidebar`), `ProjectsSettings`.
- `Macterm/Control/` — `ControlProtocol` (shared with CLI), `ControlSocketServer`, `ControlHandler`.
- `Macterm/Palette/` — `PaletteEngine` + `CommandSource`/`ProjectSource`/`DirectorySource`.
- `CLI/` — the `macterm` binary: `MactermCommand` (ArgumentParser tree), `ControlClient`, `Output`, `SSHCommand`, `TutorCommand`.
- `scripts/` — `setup.sh`, `build.sh`, `_lib.sh` (version mapping, update channel), `publish-appcast.sh`, `benchmark.py` + `_harness.py` (`MactermHarness`, shared with e2e), `e2e.sh`, `ghosttykit-api-diff.sh`, `ghostty-shim.sh`.
- `e2e/` — pytest suite. `website/` — docs site (`docs/pages/*.md`) and the Caddyfile that serves the update feed.

## Tests

### Unit (`MactermTests/`)

One `XxxTests.swift` per production type, mirroring the source path; `@testable import Macterm`, `@MainActor`. Swift Testing suites run in parallel — anything touching shared state (preferences, stores) is injected: tests needing `AppState`/`WorkspaceStore` inject a tempdir file. Helpers in `Support/`: `TreeBuilder` DSL (`H(pane("a"), V(pane("b"), pane("c")))`), `TreeRenderer`, `LayoutFixture`. Coverage targets model, persistence, palette/hotkey logic and pure helpers; SwiftUI views and libghostty bindings are not unit-tested. Poll-until-condition waits must sleep, not `Task.yield()` in a fixed loop.

### End-to-end (`e2e/`)

Launches the real Debug app hermetically via `MactermHarness` (throwaway `$HOME`, `MACTERM_BENCHMARK_DATA_DIR`, `ZMX_DIR` — the zmx socket dir is per-user, so without the override a hermetic instance shares sessions with the developer's real Macterm) and asserts through the CLI (`pane dump` etc. read libghostty's live state). Conventions: one app instance per session; take the `fresh_tab` fixture, never mutate the initial pane; every wait is a deadline poll; type commands as `/bin/sh -c "…"` with no single quotes (CI's login shell is bash 3.2); target panes explicitly; prove execution with runtime-assembled markers (`printf started-%s <nonce>`), since no idle/running signal is environment-independent. CI runs it as `Test / End-to-end`; failures upload `e2e-diagnostics`.

### Benchmarks

`mise run bench` / `.github/workflows/benchmark.yml` measure CPU-time delta, RSS and wakeups across `focused`, `workload-focused`, `workload-unfocused`, driven by Darwin notifications (`BenchmarkControl`, `MACTERM_BENCHMARK=1`, which also skips the notification prompt, Sparkle and the first-run seed). PR runs compare against a pooled median of the last 10 main runs; a cell is flagged only past ±25% and a noise floor, and the `benchmark:regression`/`improvement` label needs ≥2 corroborating cells with one under a workload state (`should_label`). The label/comment writes live in `benchmark-report.yml` (a fork PR's token is read-only).

## Releasing

Auto-updates via Sparkle (`SUFeedURL` = `https://macterm.thdxg.dev/appcast.xml`, served by `website/Caddyfile` straight off the `gh-pages` branch — a store, not a site). Tag-pushed builds release via `release.yml`; secrets: `SPARKLE_ED_PUBLIC_KEY`/`SPARKLE_ED_PRIVATE_KEY`, `HOMEBREW_TAP_PAT`, `MACTERM_SIGNING_CERT_P12`+`_PASSWORD` (a stable self-signed cert so TCC grants survive updates; **back up the private key and the cert** — losing either strands users). Release notes come from GitHub's generator (`.github/release.yml`); the version number is chosen by hand. The `/release` skill walks the ceremony; the cert recipe is in this file's history.

- **Three Sparkle channels, one feed**: a prerelease item carries `<sparkle:channel>beta|tip</sparkle:channel>`; Settings → Updates → Channel (`Preferences.updateChannel`, raw values are the wire names) opts in. A channel on a non-prerelease is a hard error in `publish-appcast.sh`. Homebrew stays stable-only.
- **Read the prerelease flag live** (`flag` job via `gh release view`), never from `github.event.release.prerelease` — the payload is frozen at dispatch and editing doesn't re-fire. Job outputs are strings: compare `== 'false'`.
- **Version ordering** (`sparkle_comparison_version` in `_lib.sh`): `0.9.0-beta.1` → `0.9.0.1`, stable `1.8.0` → `1.8.0.9999`, tip `1.24.2-tip.7` → `1.24.2.9999.7`. `build.sh` and `publish-appcast.sh` must both use it. `macterm_tip_version` filters tags to `^v[0-9]+\.[0-9]+\.[0-9]+$` because the rolling `tip` tag breaks `git describe`.
- **Tip channel** (`release-tip.yml`): every main commit with CI *passed* (Test success + Checks polled) publishes to ONE permanent prerelease edited in place, rolling `tip` tag moved **last** as the commit point, single-flight concurrency with `cancel-in-progress: false`, one tip item in the appcast, newest 3 DMGs kept. The staleness check asks whether the `tip` tag is an ancestor of the built commit — never compares against main's HEAD. `build.sh` bakes `MactermUpdateChannel` into `Info.plist` so a hand-installed tip build defaults to the tip channel; beta stamps `stable`.
- `release.yml` skips itself for `ref_name == 'tip'`. Keep GitHub Pages enabled on `gh-pages` until installs pinned to the old `thdxg.github.io` feed have moved.

## Conventions

### Code style

- SwiftFormat + SwiftLint enforced; run `mise run format`, `lint`, `test` before committing. swiftformat owns trailing commas; never write `static weak var` (the two tools fight).
- `@MainActor @Observable` on all state classes. No `@Published`/`ObservableObject`; inject via `@Environment(AppState.self)`.
- `os.Logger` only, one `private let logger = Logger(subsystem: appBundleID, category: "TypeName")` per file, **every interpolation `.public`**. View with `mise run logs`.

### Commits and PRs

- **Never add a `Co-Authored-By: Claude` trailer or any AI sign-off.**
- Subject lines say why. Split independent changes into separate commits.
- **PRs merge via squash only** — the PR title is the squash subject. On conflict, merge `main` into the branch; never rebase.
- Edit `AGENTS.md`; `CLAUDE.md` is a symlink to it.

### UI principles

- **Native SwiftUI/AppKit components only.** Accept a native limitation rather than mimic the behavior.
- All colors come from `MactermTheme`. Fixed system colors are allowed only for identity labels (`ProjectColor`, `AgentIcon.brandColor`).
- Gate Tahoe-only APIs behind `#available(macOS 26.0, *)` and, for controls, `WindowAppearance.glassSupported`.
- Settings copy: section headers Title Case, controls sentence case, buttons Title Case, descriptions via `.settingsCaption()`. `AppCommand` titles are Title Case.
- **Hover-revealed row controls change values, not view structure, and never use `.onHover`.** `SidebarProjectHeader`'s new-tab button is one `isRevealed` Bool driving padding/opacity/hit-testing; an `if/else` in a `List` row's label tears the row down and corrupts `NSTableView` reuse. Hover comes from an `NSTrackingArea` (`RowHoverTracker`, `.activeInActiveApp`) — `.onHover` has been retired three times for lag and leaked exits.
- Stacked `.dropDestination`s: only the first applied wins.
- **Anything taking mouse input over a pane needs an AppKit view.** `GhosttyTerminalNSView` wins hit testing, so SwiftUI gestures over a pane never see the press (`PaneDragSource`, `ResizeDragBand` are `NSViewRepresentable`s that forward what they don't own to `viewBeneath`). `NSHostingView` swallows hit tests even with `allowsHitTesting(false)`; override `hitTest`.

### Terminal surface rules

- Never tear down the NSView from a SwiftUI path.
- `pane.destroySurface()` kills the shell — only when a pane is permanently closed (or a remote reattach, which never kills the session).
- `createSurface()` needs a non-zero frame and a window; `TerminalSurface` defers until attached. `Pane.command`/`shell`/`env` map to libghostty's `initial_input`/`command`/`env_vars`, passed on the first build only.
- The `closeSurface` callback is asynchronous — guard double-close.
- First-responder handoff goes through `FocusRestoration` — a bare `makeFirstResponder` races window attachment.
- Any encoded key counts as typing to libghostty (clears selection, scrolls to bottom) — don't send control sequences on focus.

### Persistence

- Workspaces → `~/Library/Application Support/<display name>/workspaces_v3.json` (schema v6), projects → `projects.json`, wrapper configs beside them. Debug builds use `Macterm Debug/`, and the Debug bundle is `Macterm Debug.app` (`PRODUCT_MODULE_NAME` stays `Macterm`; spell the space wherever the bundle is named by path).
- `Pane` IDs are fresh on every restore; session identity (`sessionID`/`sessionName`, stored verbatim) is what reattaches. Snapshot always wins over a declared layout on relaunch; a layout auto-applies only on a genuine first open.
- **A directory is not an identity**: `ProjectStore.create` always appends a new project; `findOrCreate` exists only for idempotent callers (the benchmark).
- Project declarations are YAML in `~/.config/macterm/projects/` (shared across build flavors, `$HOME`-env-first via `ProjectPath.currentHome`): `name:` (display only), `path:` (identity, scp-style, `~`-contracted on write), optional `tabs:`. Schema at `assets/project.schema.json` — keep in sync. Files are written only by explicit Save Layout and the user's editor; deleted only by Settings → Projects → Layouts → Remove. Matching is by canonical `path:` with the project's name-slug as tiebreaker when one directory backs several projects (`ProjectSlug.owns`). Duplicates are surfaced, never deleted.
- `save` records `run:` as the live foreground command (`ProcessInspector.runningCommand`, remote via the probe cache), `shell:` only for a non-default shell; `apply` (`LayoutReconciler`) matches by the same `(run, cwd)`. Unparseable files surface `LayoutFileError`; empty `tabs:` is a bare declaration.
- The in-repo `.macterm/layout.yaml` was removed in v1.22.0; `LayoutFile` has no on-disk form — don't add load/serialize helpers to it.
- Settings → Projects duplicates the layout/unload/remove alerts; keep them gated on `AppState.DialogHost` so a confirmation raised from the palette doesn't also open Settings.

### Adding a new action

1. Add an `AppCommand` case (Title Case title, category, linked `HotkeyAction` if rebindable). The palette, menus and Settings pick it up.
2. If bindable, add the `HotkeyAction` to `Hotkeys.swift` with its default.
3. Handle it in the right `KeyResponder` in `Responders.swift`.
4. Add a `HotkeysTests` case for new parse/display behavior.

### Adding a new setting

Macterm-side settings go through `Preferences`; ghostty-shaped settings (theme, font, palette) belong in the user's ghostty config — don't add UI for them.

1. Add a `Preferences` property with a `didSet` writing UserDefaults.
2. Only if libghostty must be forced: `notifyConfigChanged()` in `didSet` and a line in `MactermConfig.regenerate()`.
3. Add UI to the matching `Macterm/Settings/` pane (a new pane also needs a `SettingsPane` case and a `SettingsView.detail` line).

### Windows and sidebars, AppKit reach-throughs

- **Settings window**: the sidebar is locked by `PinnedSidebar` (sets the `NSSplitViewItem`'s min == max thickness, `canCollapse = false`) *and* a `DividerShield` over the divider — SwiftUI resets the column metrics on events with no hook, so both layers are load-bearing. Replacing the split view's delegate crashes. The empty `NSToolbar` (`.unified`) is what gives it the roomier titlebar.
- **Main-window sidebar width** is persisted per window (`WindowSnapshot.sidebarWidth`, default `Preferences.defaultSidebarWidth`) and restored by `WindowAppearance.restoreSidebarWidth` via `NSSplitView.setPosition`, retried across run-loop ticks until the split view exists, because SwiftUI's autosave key embeds a runtime address (never readable back) and `navigationSplitViewColumnWidth(ideal:)` is ignored. `pinSidebarAutosaveName` gives the split view a stable name; `pruneChurnedSidebarAutosaveKeys` sweeps the old keys (matched on the `(unknown context at $` marker, skipped under tests). A collapsed sidebar is left alone. `forgetSidebarWidthRestore` clears a closed window's slot.
- Overlay-sidebar spacing and blur are separate layers: the transparent `safeAreaBar` reserves titlebar space; `SidebarTopBlurBar` stays above rows and non-interactive.

## Known Limitations

- **Quick-terminal sessions are ephemeral** (die on quit); workspace panes persist via zmx and reattach. Local sessions don't survive reboot; remote ones do.
- **Remote projects need zmx preinstalled on the host**; set `zmxPath` if PATH resolution fails. No install flow yet.
- **Remote orphan reaping only reaches sessions this installation stamped.**
- **A second window on the same tab shows a mirror**, dimmed where the pty is sized for the other view; `pane mirror` panes are not declarable in layouts, so Save/Apply Layout splits one into two sessions.
- **Adaptive background inference depends on ghostty's private renderer layout** (BGRA8 IOSurface) and fails closed; program-rendered selections (helix, vim under mouse capture) remain a residual gap.
- **Not Developer ID-signed**: first launch needs `xattr -cr /Applications/Macterm.app` or Homebrew. The stable self-signed cert keeps TCC grants across updates.
- **`macos-hidden = always` costs the menu bar**, so Settings, Quit, About and Check for Updates have no route while it is on; set Macterm's own preferences before switching it on.
- **Pane IDs are not stable across restarts.**
