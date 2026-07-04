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
```

`format`, `lint`, and `test` show a spinner and print output only on failure. **Always pass `--verbose`** (e.g. `mise run test --verbose`) to stream the raw output.

Requires macOS 14+, Swift 6.0+. Liquid glass and a few chrome refinements are macOS 26 (Tahoe) features that degrade gracefully on older systems (gated behind `WindowAppearance.glassSupported` / `#available`). GhosttyKit is a pre-built xcframework from `thdxg/ghostty` (a fork that adds CI builds); no zig toolchain needed.

`GhosttyKit.xcframework` and the `Macterm/Resources/{ghostty,terminfo,…}` contents are gitignored artifacts downloaded by `mise run setup` — **every fresh checkout, including a git worktree, must run `mise run setup`** before it can build. Don't symlink them from another checkout: `setup.sh` only re-downloads when the artifact is _absent_ (presence check, not version check), so a symlinked copy silently goes stale. To refresh a stale artifact, delete it and re-run setup.

## Releasing & Updates

Auto-updates ship via [Sparkle](https://sparkle-project.org/) — daily background check, manual via **Macterm → Check for Updates…**. Updates verify an EdDSA signature, so no `xattr` workaround after first install. No telemetry.

Tag-pushed builds release via `.github/workflows/release.yml`, which needs repo secrets: `GH_PAT` (contents:read on `thdxg/ghostty`, downloads GhosttyKit), `SPARKLE_ED_PUBLIC_KEY` (baked into `Info.plist`), and `SPARKLE_ED_PRIVATE_KEY` (signs each DMG — **back it up; losing it means users can't auto-update to any further release**). The workflow appends an `<item>` to `appcast.xml` on `gh-pages` (served at `https://thdxg.github.io/macterm/appcast.xml`, the feed URL in `Info.plist`) along with a per-version notes page rendered from the GitHub Release body (`publish-appcast.sh`).

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

## Layout

- `Macterm/App/` — `AppState`, `Preferences` (observable UserDefaults wrapper), `Hotkeys`/`KeyRouter`/`Responders`, `AppCommand`+`AppCommandActions`+`AppCommandMenu` (single source of truth for user-invokable actions — palette, menu bar, and Settings all render from `AppCommand.allCases`), `FocusRestoration` (retries `makeFirstResponder` across run-loop ticks), `Updater` (Sparkle), `AppInfo` (`appBundleID`, `appDisplayName`).
- `Macterm/Views/` — `MainWindow`, `Sidebar`, `SplitTreeView`, `TerminalPane`/`TerminalSurface`, `Terminal/GhosttyTerminalNSView` (core NSView: surface, keyboard, mouse, IME), `Terminal/SurfaceScrollView` (overlay scrollbar: surface nested in an `NSScrollView` with a spacer document view sized to scrollback), `QuickTerminal` (`NSPanel` + Carbon global hotkey), `SurfaceIncubator` (never-shown window giving off-screen tabs' panes a sized window so `createSurface()` succeeds early), `CommandPalette`, `QuitConfirmation`, `WindowAppearance` (opacity/blur/liquid glass, incl. private titlebar tree + CGS blur SPI), `TabSwitcherToolbarItem`.
- `Macterm/Ghostty/` — `GhosttyApp` (libghostty init/config/tick, resolves `GHOSTTY_RESOURCES_DIR`), `GhosttyCLI` (external CLI detection + `+ssh` probe), `GhosttyResources` (pure `GhosttyResourceResolver`), `GhosttyCallbacks`, `ThemeResolver` (`light:X,dark:Y` splits, #38), `Theme` (all UI colors).
- `Macterm/Palette/` — `PaletteEngine` (fuzzy scoring, sections, path mode) + `CommandSource`/`ProjectSource`/`DirectorySource`.
- `Macterm/Model/` — `SplitNode` (tree + `Pane`), `Workspace`/`TerminalTab`, `Project`, `TerminalSearchState`.
- `Macterm/Persistence/` — `WorkspacePersistence` (snapshots, `WorkspaceStore`), `ProjectStore`, `FileStorage`, `LayoutFile`/`LayoutBuilder`/`LayoutSerializer`/`LayoutReconciler` (declarative layouts).
- `Macterm/System/ProcessInspector.swift` — resolves a pane's foreground pid three ways: `runningCommand` (full argv via `KERN_PROCARGS2` → layout `run:`), `runningShell` (non-default shell's `exec_path` → layout `shell:`), `runningProcessName` (kernel `comm` → tab name).
- `Macterm/Config/` — `MactermConfig` (wrapper ghostty config files), `ShellIntegrationFeatures` (override merger, #75).
- `Macterm/Settings/SettingsView.swift` — preferences window.

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
- `Pane` IDs are not preserved across restarts — restore creates fresh UUIDs.
- Declarative layouts are an _authorable_ file at `.macterm/layout.yaml` in the project root, applied/saved on demand via `applyLayout`/`saveLayout`. An unparseable file surfaces `LayoutFileError` and is never applied. JSON schema at `assets/layout.schema.json` — keep it in sync when layout types change.
  - A committed layout file is the source of truth: on relaunch, `restoreSelection` skips the workspace snapshot for any project that has one; a project's first open auto-applies it (with no live panes the reconcile is pure-spawn, never destructive).
  - `save` records a pane's `run:` as its **live** foreground command (`ghostty_surface_foreground_pid` → `ProcessInspector` argv via `KERN_PROCARGS2`) — an idle prompt saves no `run`. `shell:` is recorded only when the pane sits in a _non-default_ shell. `run` and `shell` are mutually exclusive on a leaf.
  - `apply` (`LayoutReconciler`) matches live panes to declared ones by that same live `(run, cwd)`; a pane that quit its declared command is respawned. A plain-shell leaf matches an idle pane positionally, but a declared `shell:` only reuses an idle pane running that shell (basename compare). The live-command/live-shell lookups are injected closures (default `ProcessInspector`), so the logic is unit-testable.
  - The file's top-level `name:` is the project it was saved for — a mismatch on apply stages a confirmation warning. Tab `name:` is the tab's title, matched to live tabs during reconcile.

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

- **No process persistence** — closing the app kills all shells (recommend tmux/zellij).
- **Single window only** — multi-window would require a tmux-like daemon; out of scope.
- **Not code-signed with a Developer ID** — first launch needs `xattr -cr /Applications/Macterm.app` (or Homebrew install); Sparkle updates verify EdDSA after that.
- **Pane IDs not stable across restarts** — fresh views are created on restore.
