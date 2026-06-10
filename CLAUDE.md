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

`format`, `lint`, and `test` show a spinner and print output only on failure. **Always pass `--verbose`** (e.g. `mise run test --verbose`) to stream the raw output — a spinner-only run hides the logs you need to confirm what happened, even on success.

Requires macOS 26+, Swift 6.0+. GhosttyKit is a pre-built xcframework from `thdxg/ghostty` (a fork that adds CI builds). No zig toolchain needed for development.

`GhosttyKit.xcframework` and the `Macterm/Resources/{ghostty,terminfo,…}` contents are gitignored build artifacts downloaded by `mise run setup` — they don't exist on a fresh clone. **A new checkout, including a git worktree, must run `mise run setup` to populate them** before it can build. Don't symlink them in from another checkout: `setup.sh` only re-downloads when the artifact is absent (it's a presence check, not a version check), so a symlinked-in copy can silently go stale, and a whole-directory `Resources` symlink also shows up as untracked. (To refresh a stale artifact, delete it and re-run `mise run setup`.)

## Updates

Macterm ships with automatic updates via [Sparkle](https://sparkle-project.org/). A version check runs daily in the background and can be triggered manually from **Macterm → Check for Updates…** or in **Settings → Updates**. Updates are verified with an EdDSA signature baked into the app, so later versions install without any `xattr` workaround. No telemetry is collected.

## Releasing

Tag-pushed builds are released via `.github/workflows/release.yml`. The workflow needs these secrets configured on the repo:

- `GH_PAT` — PAT with `contents:read` on `thdxg/ghostty` (used to download GhosttyKit).
- `SPARKLE_ED_PUBLIC_KEY` — the EdDSA public key baked into `Info.plist`.
- `SPARKLE_ED_PRIVATE_KEY` — the matching private key, used to sign each release DMG.

Generate the keypair once by downloading Sparkle and running `./bin/generate_keys`. Store the public key in `SPARKLE_ED_PUBLIC_KEY` (it's not secret, but keeping it as a secret avoids committing it to the repo) and the private key in `SPARKLE_ED_PRIVATE_KEY`. Back the private key up in a password manager — losing it means users cannot auto-update to any further release.

The workflow pushes a new `<item>` to `appcast.xml` on the `gh-pages` branch, which GitHub Pages serves at `https://thdxg.github.io/macterm/appcast.xml` — the feed URL baked into `Info.plist`. The item also includes a `<sparkle:releaseNotesLink>` to a per-version notes page (`notes/v<version>.html`) also published on `gh-pages`; Sparkle's update dialog loads that into its WebView. Notes are sourced from the GitHub Release body (`--generate-notes` produces them) and rendered to HTML via the GitHub API's `/markdown` endpoint in `publish-appcast.sh`.

## Architecture Overview

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

**`GhosttyTerminalNSView` is owned by its `Pane` model, not by SwiftUI.** `TerminalSurface` is an `NSViewRepresentable` whose `makeNSView` returns `pane.ensureNSView()` — a cached instance that lives for the lifetime of the `Pane`. SwiftUI's `dismantleNSView` is a no-op; the NSView is only destroyed when `pane.destroySurface()` is called explicitly (pane close, app shutdown).

This exists because ghostty surfaces are tightly coupled to their `NSView` + `CAMetalLayer`. If SwiftUI destroyed and recreated the NSView on every tree reshape or tab switch, the surface would die. Anchoring ownership in the model instead of the view hierarchy keeps surfaces alive across SwiftUI lifecycle events without needing a portal/overlay.

**Files:**

- `Views/TerminalPane.swift` — `TerminalPane` + `TerminalSurface` (`NSViewRepresentable` that borrows `pane.nsView`)
- `Model/SplitNode.swift` — `Pane` owns the lazily-created `GhosttyTerminalNSView`; `destroySurface()` tears it down
- `Views/Terminal/GhosttyTerminalNSView.swift` — The NSView itself (surface, keyboard, mouse, IME)

### State Management

- **`AppState`** — Single `@Observable` instance, passed via `.environment()`. Owns workspaces, active project, sidebar visibility, tab cycling, pending close dialogs. All workspace/tab/pane mutations go through here.
- **`ProjectStore`** — Global project list. Separate from AppState because it persists independently.
- **`Workspace`** — Per-project tab collection. Keyed by project ID in `AppState.workspaces`.
- **`TerminalTab`** — Owns a `SplitNode` tree and focused pane ID.
- **`SplitNode`** — Recursive enum: `.pane(Pane)` or `.split(SplitBranch)`. Tree operations: `splitting`, `removing`, `findPane`, `allPanes`, `paneFrames`, `nearestPane`.

### Single Window Enforcement

The app blocks additional windows. `WindowGroup`'s `.newItem` command is replaced with a custom "Show Window" item (Cmd+N) that calls `makeKeyAndOrderFront` on the existing window. The close button hides (`orderOut`) instead of closing, preserving all terminal surfaces. Dock icon click reopens via an `NSWorkspace.didActivateApplicationNotification` observer in `AppDelegate.reopenIfNeeded()` — `applicationShouldHandleReopen` alone isn't reliable through SwiftUI's `@NSApplicationDelegateAdaptor`, and AppKit reports `canBecomeMain = false` on ordered-out windows so the filter walks `NSApp.windows` for any hidden non-panel window.

### Hotkey System

All keybinds are configurable via `HotkeyAction` enum + `HotkeyRegistry`. `KeyRouter` installs a single `NSEvent.addLocalMonitorForEvents` at launch and dispatches events through a chain of `KeyResponder` implementations defined in `Responders.swift` (pending-close dialog, tab cycling, command palette, hotkey actions). `isAppShortcut` in `GhosttyTerminalNSView` checks all registered hotkeys to let app shortcuts pass through.

Hotkey defaults are in `Hotkeys.swift`. User overrides are stored in UserDefaults (`macterm.hotkey.<action_id>`).

### Quick Terminal

A floating `NSPanel` that reuses the same `TerminalTab` / `SplitNode` / `Pane` model as the main window — no separate cache needed because `Pane` owns its NSView. Activated via `Ctrl+\`` (Carbon hot key for global capture).

### Tab naming

A tab's auto-title (`Workspace.autoTitle` → each pane's `Pane.processTitle`) is the name of the pane's live **foreground process** (`hx`, `btop`) — never the terminal's OSC title — falling back to the shell name when idle, and overridden by a user-set `customTitle`. This mirrors tmux's `automatic-rename` on macOS: `ProcessInspector.runningProcessName` reads the foreground pid's short kernel `comm` (`proc_pidinfo` `PROC_PIDT_SHORTBSDINFO`), a path-free basename; idle panes use `Pane.defaultShellName` (the login shell from `getpwuid`, not `$SHELL`).

`AppState` polls every live pane on a timer (`refreshAllForegroundProcesses`, ~250ms, republishing only on change); an OSC title arriving (`onTitleChange`) is an extra command-boundary signal that triggers the same refresh, but its string is unused. The OSC title is deliberately ignored for naming: ghostty's `SET_TITLE` carries no provenance, so a shell that titles itself from its prompt (nushell, Starship, ghostty shell-integration — emitting `~/dir`, `host:~/dir`) is indistinguishable from a program setting its own title, and honoring it makes the tab show the cwd instead of the command. Pane titles aren't persisted — they're derived live from the running process.

## File Map

### App Layer (`Macterm/App/`)

| File                        | Purpose                                                                                                       |
| --------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `MactermApp.swift`          | `@main` entry, `WindowGroup`, `AppDelegate`                                                                   |
| `AppState.swift`            | Central observable state — workspaces, projects, tab/pane lifecycle. `WorkspaceStore` is injectable for tests |
| `Preferences.swift`         | Observable UserDefaults wrapper (`Preferences.shared`) for app-level settings                                 |
| `Hotkeys.swift`             | `HotkeyAction` enum, `HotkeyRegistry` for parsing/matching/display                                            |
| `KeyRouter.swift`           | Installs the single `NSEvent` local monitor and runs events through the responder chain                       |
| `Responders.swift`          | Ordered `KeyResponder` implementations (pending-close, tab cycle, command palette, hotkeys)                   |
| `FocusRestoration.swift`    | Retries `makeFirstResponder` across run loop ticks until the pane's NSView is in a window                     |
| `RecencyStack.swift`        | Bounded most-recent-first stack of unique IDs (tab/pane focus history)                                        |
| `Notifications.swift`       | Custom `Notification.Name` constants                                                                          |
| `AppCommand.swift`          | Single source of truth for user-invokable actions; palette and Settings render from `AppCommand.allCases`     |
| `AppCommandActions.swift`   | `AppCommandContext` + `AppCommand.action(in:)` — the closure each command runs, shared by palette and menu    |
| `AppCommandMenu.swift`      | `AppCommandMenuItem` SwiftUI view that renders an `AppCommand` in the menu bar via the same action closure    |
| `NotificationHandler.swift` | `UNUserNotificationCenterDelegate` for OS-level user notifications                                            |
| `AppTerminationState.swift` | `isTerminating` flag so `windowShouldClose` can distinguish user-close (hide) from quit (let close)           |
| `Updater.swift`             | Sparkle wrapper (`Updater.shared`) + `CheckForUpdatesMenuItem` view                                           |
| `AppInfo.swift`             | `appBundleID` constant (the running app's bundle ID) — used as the os.Logger subsystem (see "Logging")        |

### Views (`Macterm/Views/`)

| File                                   | Purpose                                                                                                                                                                                                               |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `MainWindow.swift`                     | Main window layout, `WorkspaceView`, `WindowStyler`                                                                                                                                                                   |
| `WindowAppearance.swift`               | Window opacity/blur/liquid glass — sets `NSWindow.backgroundColor`, dives into private titlebar view tree, calls CGS blur SPI, or installs a macOS 26 `NSGlassEffectView` (`MactermGlassView`) below the content view |
| `Sidebar.swift`                        | Project/tab list with native `List(selection:)`                                                                  |
| `SplitTreeView.swift`                  | Recursive split rendering with draggable dividers                                                                |
| `TerminalPane.swift`                   | `TerminalPane` + `TerminalSurface` (`NSViewRepresentable` borrowing `pane.nsView`) + search bar overlay          |
| `Terminal/GhosttyTerminalNSView.swift` | Core terminal NSView — surface, keyboard, mouse, IME                                                             |
| `Terminal/SurfaceScrollView.swift`     | Native overlay scrollbar: nests the Metal surface in an `NSScrollView` with a blank spacer document view sized to scrollback (Ghostty 1.3.0+ approach) |
| `SearchBar.swift`                      | Terminal search UI                                                                                               |
| `QuickTerminal.swift`                  | Quick terminal `NSPanel`, Carbon global hotkey                                                                   |
| `SurfaceIncubator.swift`               | Never-shown `NSWindow` (`SurfaceIncubator.shared`) that starts off-screen tabs' shells by giving their panes a sized window so `createSurface()` succeeds before the tab is viewed |
| `CommandPalette.swift`                 | `Cmd+Shift+P` / `Cmd+P` command palette                                                                          |
| `QuitConfirmation.swift`               | Native `Table`-based confirmation shown when quitting with panes still running foreground processes              |
| `TabSwitcherToolbarItem.swift`         | Numbered segmented control in the title bar mirroring a 5-tab sliding window of the active project's tabs        |

### Ghostty Integration (`Macterm/Ghostty/`)

| File                     | Purpose                                                                                            |
| ------------------------ | -------------------------------------------------------------------------------------------------- |
| `GhosttyApp.swift`       | libghostty init, config, tick loop, color queries; resolves `GHOSTTY_RESOURCES_DIR`                |
| `GhosttyCLI.swift`       | Detects the external `ghostty` CLI (Ghostty.app) and probes whether it supports the `+ssh` action; lists the shell-integration features gated on it |
| `GhosttyResources.swift` | Pure `GhosttyResourceResolver` — picks the resources dir (testable selection logic)                |
| `GhosttyCallbacks.swift` | Routes libghostty callbacks to terminal views                                                      |
| `ThemeResolver.swift`    | Pure resolver for `theme = light:X,dark:Y` splits — libghostty's config getters can't (issue #38)  |
| `Theme.swift`            | All UI colors derived from ghostty config                                                          |

### Palette (`Macterm/Palette/`)

| File                    | Purpose                                                                 |
| ----------------------- | ----------------------------------------------------------------------- |
| `PaletteEngine.swift`   | Fuzzy-scoring engine, section ordering, path-mode dispatch              |
| `CommandSource.swift`   | Iterates `AppCommand.allCases` to feed action commands into the palette |
| `ProjectSource.swift`   | Project items (open/rename/delete) for the palette                      |
| `DirectorySource.swift` | Filesystem path completions when the palette is in path mode            |

### Settings (`Macterm/Settings/`)

| File                 | Purpose                                                                      |
| -------------------- | ---------------------------------------------------------------------------- |
| `SettingsView.swift` | Preferences window — font, theme, window opacity/blur, hotkeys, misc toggles |

### Model (`Macterm/Model/`)

| File                        | Purpose                                                      |
| --------------------------- | ------------------------------------------------------------ |
| `SplitNode.swift`           | Recursive split tree, `Pane`, `SplitBranch`, tree operations |
| `Workspace.swift`           | `TerminalTab`, `Workspace` — tab lifecycle and history       |
| `Project.swift`             | `Project` struct                                             |
| `TerminalSearchState.swift` | Search state with Combine debounce                           |

### Persistence (`Macterm/Persistence/`)

| File                         | Purpose                                                                                                                      |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `WorkspacePersistence.swift` | Snapshot types, `WorkspaceStore`, `WorkspaceSerializer`                                                                      |
| `ProjectStore.swift`         | `ProjectStore` — project CRUD + JSON persistence                                                                             |
| `FileStorage.swift`          | App Support directory helpers                                                                                                |
| `LayoutFile.swift`           | Declarative layout file format + YAML (Yams) parse/encode: `LayoutFile`/`LayoutTab`/`LayoutNode`/`LayoutPane`/`LayoutBranch` |
| `LayoutBuilder.swift`        | `LayoutNode` → `SplitNode` tree builder (resolves cwd/shell per leaf)                                                        |
| `LayoutSerializer.swift`     | Live workspace → layout file (the `save` direction)                                                                          |
| `LayoutReconciler.swift`     | Minimal-destruction `apply`: matches live panes to declared by `(run, cwd)`, reuses or destroys                              |

### System (`Macterm/System/`)

| File                     | Purpose                                                                                                                                                                                                                                                                                                                     |
| ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ProcessInspector.swift` | Resolves a pane's foreground pid (`GhosttyTerminalNSView.foregroundPID`) three ways: `runningCommand` reads the full argv via `KERN_PROCARGS2` (`saveLayout` → a pane's `run:`); `runningShell` reads the shell's `exec_path` when the foreground is a non-default shell (`saveLayout` → `shell:`, and reconcile shell-match); `runningProcessName` reads the short kernel `comm` via `proc_pidinfo` (the tab name — see "Tab naming") |

### Config (`Macterm/Config/`)

| File                             | Purpose                                                                                                         |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `MactermConfig.swift`            | Generates the two wrapper ghostty config files Macterm sandwiches around the user's                              |
| `ShellIntegrationFeatures.swift` | Pure merger for the `shell-integration-features` override — user's flags + Macterm's forced `no-*` flags (#75)   |

Macterm reads the user's `~/.config/ghostty/config` (path configurable in Settings → General → Ghostty Config). The user is the source of truth for every ghostty setting — themes, fonts, palettes, keybinds, etc. `MactermConfig.regenerate()` writes two private files in App Support:

- **`macterm-defaults.conf`** — first-launch tasteful defaults (Rose Pine, 16pt, padding, `macos-option-as-alt = true`). User's Ghostty config overrides each line.
- **`macterm-overrides.conf`** — keys Macterm absolutely needs to lock: `background-opacity = 0` and `background-blur = 0` so ghostty renders fully transparent and `WindowAppearance` can composite translucency itself without double-tinting, plus (when the external ghostty CLI is missing/too old) `GHOSTTY_BIN_DIR` and a `shell-integration-features` line disabling the CLI-dependent features. The latter can't be written bare — libghostty re-parses that key from defaults on every occurrence, so a bare line would wipe the user's own flags (e.g. `no-cursor`); `ShellIntegrationFeatures.overrideValue` re-emits the user's effective value with our `no-*` flags appended (#75). Because the override depends on the user's config content, `GhosttyApp.loadConfig` calls `regenerate()` before every load.

`GhosttyApp.loadConfig` loads them in order: `defaults → user's Ghostty config → overrides`. libghostty does last-wins merge, so the user's config overrides our defaults and our overrides override the user. See the README's "Configuration" section for the user-facing version of what's overridden vs honored.

Macterm-specific UI state (window opacity/blur, quick terminal, hotkeys, auto-tile) lives in `Preferences` and never touches the ghostty config pipeline.

### Bundled ghostty resources (standalone operation)

libghostty reads two things at runtime via `GHOSTTY_RESOURCES_DIR`: `shell-integration/` and (via terminfo, below) `terminfo/`, plus `themes/` when a named theme is used. Macterm ships them in its own app bundle **mirroring a real Ghostty.app layout** — `Contents/Resources/ghostty/{themes,shell-integration}` with the compiled terminfo DB at the sibling `Contents/Resources/terminfo/` — so it runs with no Ghostty.app install. The tarball is downloaded by `setup.sh` from the `thdxg/ghostty` release (`ghostty-resources.tar.gz`, which itself ships the `ghostty/` + `terminfo/` layout) and folder-referenced into the bundle via `project.yml`. Nothing under `Macterm/Resources/` is committed — it's all gitignored and regenerated by `setup.sh`.

`GhosttyApp.resolveResources()` points `GHOSTTY_RESOURCES_DIR` at `Contents/Resources/ghostty` (falling back to an installed `Ghostty.app` if the bundle is missing resources, e.g. an unprepared dev checkout). It always resolves from our own candidates and ignores any inherited `GHOSTTY_RESOURCES_DIR` — a stale value (e.g. an installed app without terminfo) would otherwise shadow our complete bundle. The selection logic is factored into the pure, unit-tested `GhosttyResourceResolver` in `GhosttyResources.swift`.

Two non-obvious terminfo facts (the regression behind issues #39/#40, where 1.13.3 pointed `GHOSTTY_RESOURCES_DIR` at a bundle shipping no terminfo, breaking `TERM=xterm-ghostty` and key input):

- **TERMINFO must NOT be set by us — the bundle layout makes libghostty derive it correctly.** At shell spawn libghostty _unconditionally overwrites_ `TERMINFO` with `dirname(GHOSTTY_RESOURCES_DIR)/terminfo` (`src/termio/Exec.zig`), so any `setenv` we do is clobbered. Because our resources dir is `.../Resources/ghostty`, that derivation lands on the sibling `.../Resources/terminfo` — exactly the dir we ship. This is why terminfo MUST be a sibling of `ghostty/`, never inside it (a flat layout reintroduces #39/#40). `BundledResourcesTests` asserts this invariant.
- **The terminfo tree uses the macOS hashed layout.** The compiled `xterm-ghostty` entry lives at `terminfo/78/xterm-ghostty` (`x` = 0x78), not `terminfo/x/...`. It's a `tic -x` compiled tree, shipped verbatim from the ghostty build.

### Tests (`MactermTests/`)

Mirror the production tree. Use `@testable import Macterm` and `@MainActor` on test classes. `mise run test` runs the suite locally and on every CI push.

| Path                                                                                                                        | Covers                                                                                                     |
| --------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `Model/SplitNodeTests.swift`, `SplitNodeResizeTests.swift`, `SplitNodeGeometryTests.swift`, `SplitNodeRebalanceTests.swift` | Tree ops, resize, geometry (`paneFrames`, `nearestPane`), rebalance                                        |
| `Model/TerminalTabTests.swift`                                                                                              | Focus history, split/resize/removePane, HV-close regression                                                |
| `Model/WorkspaceTests.swift`                                                                                                | Tab lifecycle, recency, reorder                                                                            |
| `Model/PaneTests.swift`                                                                                                     | `processTitle` (foreground-process name vs shell fallback), `destroySurface` idempotency                   |
| `App/AppStateTests.swift`                                                                                                   | Integration: splitPane/closePane/focusPaneInDirection via injected `WorkspaceStore`                        |
| `App/RecencyStackTests.swift`                                                                                               | Generic stack helper                                                                                       |
| `App/HotkeysTests.swift`                                                                                                    | `parseShortcut`, `displayString`, `HotkeyAction` sanity                                                    |
| `Palette/PaletteEngineTests.swift`                                                                                          | `fuzzyScore`, engine sections/sort/path-mode                                                               |
| `Palette/CommandSourceTests.swift`                                                                                          | `CommandSource` palette-item generation from `AppCommand.allCases`                                         |
| `Ghostty/GhosttyCLITests.swift`                                                                                             | External `ghostty` CLI detection, bin-dir priority, `+ssh`-support gating (`GhosttyCLI`)                   |
| `Ghostty/GhosttyResourceResolverTests.swift`                                                                                | Resource dir selection (`GhosttyResourceResolver`)                                                         |
| `Ghostty/BundledResourcesTests.swift`                                                                                       | Bundle layout: terminfo is a sibling of `ghostty/`, has `78/xterm-ghostty`, shells, themes (#39/#40 guard) |
| `Ghostty/ThemeResolverTests.swift`                                                                                          | `theme = light:X,dark:Y` split parsing + side selection (`ThemeResolver`, #38)                             |
| `Config/ShellIntegrationFeaturesTests.swift`                                                                                | `shell-integration-features` user-value extraction + override merge (`ShellIntegrationFeatures`, #75)      |
| `Persistence/WorkspaceSerializerTests.swift`                                                                                | Snapshot/restore round-trip + on-disk via `WorkspaceStore`                                                 |
| `Persistence/LayoutFileTests.swift`                                                                                         | YAML parse/encode round-trip, tab-is-a-node + nested `split:` format, cwd resolution                       |
| `Persistence/LayoutSerializerTests.swift`                                                                                   | Live workspace → layout file (topology, project-relative cwd, `run`, non-default `shell:`)                 |
| `Persistence/LayoutReconcilerTests.swift`                                                                                   | Minimal-destruction apply: keep/resize/respawn/kill by `(run, cwd)` identity, plain-shell positional match, `shell:`-mismatch respawn |
| `System/ProcessInspectorTests.swift`                                                                                        | `ProcessInspector.argv` syscall parsing against real spawned subprocesses                                  |
| `Views/SurfaceScrollGeometryTests.swift`                                                                                    | Pure row↔pixel scrollback geometry conversion (Y-down rows ↔ Y-up points) for `SurfaceScrollView`          |
| `Support/TreeBuilder.swift`                                                                                                 | DSL: `H(pane("a"), V(pane("b"), pane("c")))` → `(SplitNode, [name: UUID])`                                 |
| `Support/TreeRenderer.swift`                                                                                                | Inverse DSL for readable assertions                                                                        |

**Testing conventions:**

- One `XxxTests.swift` per production type, mirroring the source path.
- Shared helpers live in `MactermTests/Support/`.
- Tests that need `AppState` or `WorkspaceStore` inject a tempdir file — never touch `~/Library/Application Support/`.
- UI (SwiftUI views, AppKit surfaces, ghostty libghostty bindings) is not unit-tested; coverage targets the model + persistence + palette/hotkey logic, plus pure side-effect-free helpers (e.g. `GhosttyResourceResolver`).
- `BundledResourcesTests` is an artifact check, not a unit test: it asserts `Macterm/Resources/` (populated by `setup.sh`) ships the files libghostty needs, and `#require`-skips on a fresh checkout before setup has run.

## Conventions

### Code Style

- **SwiftFormat** + **SwiftLint** enforced. Run `mise run format`, `mise run lint`, and `mise run test` before committing.
- `@MainActor @Observable` on all state classes.
- No `@Published` / `ObservableObject` — use `@Observable` (Swift 5.9+).
- Environment injection: `@Environment(AppState.self)`, not `@EnvironmentObject`.

### Commit Conventions

- **Never add a `Co-Authored-By: Claude` trailer or any AI sign-off** to commits. Commits are authored by the human committer only.
- Subject line focuses on the "why" in 1–2 sentences. Split logically independent changes into separate commits.
- **PRs merge via squash only** — merge-commit and rebase merging are disabled on the repo. The whole branch lands as one commit on `main`, so per-commit history within a PR is discarded; make the PR title a good squash subject. When a PR conflicts, resolve it by merging `main` into the branch (squash flattens the merge commit away anyway); never rebase the branch onto `main` (the "Rebase and merge" button is intentionally unavailable).

### UI Principles

- **Always use native SwiftUI/AppKit components.** Never mimic native behavior with custom implementations. If a native component has a limitation, accept it rather than building a workaround.
- All colors come from `MactermTheme`, which derives from the ghostty theme config. No hardcoded colors.
- The app targets macOS 26 (Tahoe) with liquid glass appearance.

### Terminal Surface Rules

- `GhosttyTerminalNSView` is owned by `Pane`, not SwiftUI. `TerminalSurface.dismantleNSView` is a no-op — never tear down the NSView from a SwiftUI path.
- `pane.destroySurface()` kills the shell process. Only call it when a pane is permanently closed (AppState handles this after the pane leaves the tree).
- `createSurface()` needs a non-zero frame and a window. `TerminalSurface` defers creation via `DispatchQueue.main.async` until the view is attached to a window. When the `Pane` carries a `command`/`shell`/`env` (from a declarative layout), they're passed to libghostty's surface config as `initial_input` (the `run` command typed into the shell), `command` (the shell binary), and `env_vars`.
- The `closeSurface` callback from ghostty fires asynchronously. Guard against double-close.
- First-responder handoff after tree reshapes/tab switches must go through `FocusRestoration.restoreFocus(...)` — not a bare `makeFirstResponder`, which races the NSView's window attachment.

### Persistence

- Workspaces saved to `~/Library/Application Support/Macterm/workspaces_v3.json`
- Projects saved to `projects.json` in the same directory
- Declarative layouts are an _authorable_ file at `.macterm/layout.yaml` in the project root — distinct from the machine-written workspace snapshot. Applied/saved on demand via the `applyLayout` / `saveLayout` commands; `apply` reconciles with minimal destruction (`LayoutReconciler`), and an unparseable file is surfaced via `LayoutFileError` and never applied. The format has a JSON schema at `assets/layout.schema.json`; `LayoutFile.yaml()` prepends a `yaml-language-server` modeline pointing at it so saved files get editor completion/validation. Keep the schema in sync when the layout types change
  - A committed layout file is the source of truth: on relaunch, `restoreSelection` _skips_ restoring the workspace snapshot for any project that has a `.macterm/layout.yaml`, so it rebuilds from the layout instead. Projects with no layout file restore their snapshot as before
  - On a project's first open with no live workspace, `selectProject` → `autoApplyLayoutOnFirstOpen` applies the layout file if present. With no live panes the reconcile is pure-spawn (never destructive, never prompts)
  - `save` records each pane's `run` as the command it's _currently_ running (its live foreground command), not the command it was spawned with — so a pane that has quit its command saves no `run`. The command comes from `ghostty_surface_foreground_pid` (libghostty hands us the pane's foreground pid directly; requires a GhosttyKit build from ~2026-04+), resolved to an argv string by `ProcessInspector` via `KERN_PROCARGS2`. An idle shell prompt yields no `run`. `save` records `shell:` only when the pane is sitting in a *non-default* shell (one the user dropped into, e.g. `zsh` launched from `nu` — `ProcessInspector.runningShell`); a pane idle in the login shell records no `shell:` so the layout stays portable. `run` and `shell` are mutually exclusive on a leaf (the foreground is either a command or a shell)
  - `apply` (`LayoutReconciler`) matches a live pane to a declared one by that same _live_ foreground command (+ cwd), so a pane that quit its declared command is treated as out of sync and respawned. A declared plain-shell leaf (no `run:`) matches an idle pane positionally — but if it declares a specific `shell:`, it only reuses an idle pane *running that shell* (compared by basename via `liveShellName`), so applying a layout that swaps a pane's shell respawns it. The live-command / live-shell lookups are injected closures on both `LayoutReconciler.plan` and `LayoutSerializer`, defaulting to `ProcessInspector`, so the logic is unit-testable without a live surface
  - The file's top-level `name:` is the project it was saved for. On `apply`, if `name` is present and differs from the active project, `applyLayout` stages a `pendingLayoutApply` with `mismatchedProjectName` set so the confirmation dialog warns before proceeding (a missing/matching `name` applies silently). Tab `name:` is separate — it's the tab's title, matched to live tabs during reconcile
- User's ghostty config read from `~/.config/ghostty/config` by default (path configurable in Settings)
- Macterm's wrapper config files written to `~/Library/Application Support/Macterm/macterm-defaults.conf` and `macterm-overrides.conf` on launch. Not user-editable; they're transport between Macterm and libghostty around the user's real config.
- `Pane` IDs are not preserved across restarts — `restoreNode` creates new `Pane` instances with fresh UUIDs

### Adding a New Action

1. Add a case to `AppCommand` in `AppCommand.swift` with its title, category, and (if rebindable) linked `HotkeyAction`. The palette picks it up automatically via `AppCommand.allCases`. **All action titles must be Title Case** (the macOS menu convention) — capitalize principal words, leave minor words (`for`, `with`, `to`, `the`, etc.) lowercase unless first/last, e.g. "Check for Update", "Replace Project Path with Current Directory".
2. If the command is keyboard-bindable, add the corresponding `HotkeyAction` case to `Hotkeys.swift` with its default shortcut.
3. Add a handler in the appropriate `KeyResponder` in `Responders.swift` (or extend an existing one).
4. The terminal's `isAppShortcut` automatically picks it up via `HotkeyAction.allCases`.
5. Add a test case to `HotkeysTests.swift` if the action introduces new parse/display behavior.

### Logging

Use `os.Logger` for all diagnostic output — never `print()` or `NSLog()`. Logs flow through the unified logging system and are viewable with `mise run logs`.

```swift
import os
private let logger = Logger(subsystem: appBundleID, category: "MyComponent")

logger.debug("...")   // verbose, dev-only; stripped in release unless enabled
logger.info("...")    // lifecycle events, state transitions
logger.warning("...") // unexpected but recoverable
logger.error("...")   // failures
```

Always mark interpolated values `.public` — the default is `.private`, which redacts them in the log stream:

```swift
logger.info("selectProject: \(project.name, privacy: .public)")
```

Every file that emits logs gets its own `private let logger` at the top with a `category` matching the type name. The subsystem is the shared `appBundleID` constant (`App/AppInfo.swift`), which is `Bundle.main.bundleIdentifier` so debug builds log to `com.thdxg.macterm.debug` and release to `com.thdxg.macterm`.

### Adding a New Setting

Macterm-side settings (window opacity, quick terminal frame, auto-tile, etc.) flow through `Preferences` (UserDefaults). Ghostty-shaped settings (theme, font, palette, etc.) belong in the user's Ghostty config — don't add UI for them.

For Macterm-side settings:

1. Add a property to `Preferences` with a `didSet` that writes to UserDefaults.
2. If the setting affects libghostty (e.g. it's something we'd want to force-write into `macterm-overrides.conf` because it conflicts with a user value), call `notifyConfigChanged()` from `didSet` and add the corresponding line to `MactermConfig.regenerate()`'s overrides file. The bar here is "Macterm breaks without it" — most settings don't need this.
3. Add UI to `SettingsView.swift` in the appropriate `Section`, binding to `Preferences.shared.x`.

## Known Limitations

- **No process persistence** — closing the app kills all shell processes. Recommend tmux/zellij for session persistence.
- **Single window only** — multi-window requires process syncing (tmux-like daemon) which is out of scope.
- **Not code-signed with a Developer ID** — first-launch users must run `xattr -cr /Applications/Macterm.app` to clear the quarantine flag (or install via Homebrew, which strips it automatically). Subsequent auto-updates go through Sparkle and verify an EdDSA signature, so the workaround isn't needed again.
- **Pane IDs not stable across restarts** — view cache entries from previous sessions are orphaned. Fresh views are created on restore.
