# Macterm Codebase Guide

A macOS terminal emulator built with SwiftUI and libghostty. Single-window app with project-based workspace management, split panes, and a quick terminal overlay.

## Build & Run

```bash
mise install          # Install tools (gh, swiftformat, swiftlint)
mise run setup        # Download pre-built GhosttyKit.xcframework
mise run run          # Build and launch (debug)
mise run format       # Auto-fix formatting with swiftformat
mise run lint         # swiftlint
mise run test         # Run the test suite
mise run build        # Release build + DMG
```

Requires macOS 26+, Swift 6.0+. GhosttyKit is a pre-built xcframework from `thdxg/ghostty` (a fork that adds CI builds). No zig toolchain needed for development.

## Updates

Macterm ships with automatic updates via [Sparkle](https://sparkle-project.org/). A version check runs daily in the background and can be triggered manually from **Macterm → Check for Updates…** or in **Settings → Updates**. Updates are verified with an EdDSA signature baked into the app, so later versions install without any `xattr` workaround. No telemetry is collected.

## Releasing

Tag-pushed builds are released via `.github/workflows/release.yml`. The workflow needs these secrets configured on the repo:

- `GH_PAT` — PAT with `contents:read` on `thdxg/ghostty` (used to download GhosttyKit).
- `SPARKLE_ED_PUBLIC_KEY` — the EdDSA public key baked into `Info.plist`.
- `SPARKLE_ED_PRIVATE_KEY` — the matching private key, used to sign each release DMG.

Generate the keypair once by downloading Sparkle and running `./bin/generate_keys`. Store the public key in `SPARKLE_ED_PUBLIC_KEY` (it's not secret, but keeping it as a secret avoids committing it to the repo) and the private key in `SPARKLE_ED_PRIVATE_KEY`. Back the private key up in a password manager — losing it means users cannot auto-update to any further release.

The workflow pushes a new `<item>` to `appcast.xml` on the `gh-pages` branch, which GitHub Pages serves at `https://thdxg.github.io/macterm/appcast.xml` — the feed URL baked into `Info.plist`.

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

The app blocks additional windows. `Cmd+N` focuses the existing window. `WindowGroup` menu items for new windows and tab bar are removed. The window close button hides (`orderOut`) instead of closing, preserving all terminal surfaces. Dock icon click reopens the hidden window.

### Hotkey System

All keybinds are configurable via `HotkeyAction` enum + `HotkeyRegistry`. `KeyRouter` installs a single `NSEvent.addLocalMonitorForEvents` at launch and dispatches events through a chain of `KeyResponder` implementations defined in `Responders.swift` (pending-close dialog, tab cycling, command palette, hotkey actions). `isAppShortcut` in `GhosttyTerminalNSView` checks all registered hotkeys to let app shortcuts pass through.

Hotkey defaults are in `Hotkeys.swift`. User overrides are stored in UserDefaults (`macterm.hotkey.<action_id>`).

### Quick Terminal

A floating `NSPanel` that reuses the same `TerminalTab` / `SplitNode` / `Pane` model as the main window — no separate cache needed because `Pane` owns its NSView. Activated via `Ctrl+\`` (Carbon hot key for global capture).

## File Map

### App Layer (`Macterm/App/`)

| File                     | Purpose                                                                                                       |
| ------------------------ | ------------------------------------------------------------------------------------------------------------- |
| `MactermApp.swift`       | `@main` entry, `WindowGroup`, `AppDelegate`                                                                   |
| `AppState.swift`         | Central observable state — workspaces, projects, tab/pane lifecycle. `WorkspaceStore` is injectable for tests |
| `Preferences.swift`      | Observable UserDefaults wrapper (`Preferences.shared`) for app-level settings                                 |
| `Hotkeys.swift`          | `HotkeyAction` enum, `HotkeyRegistry` for parsing/matching/display                                            |
| `KeyRouter.swift`        | Installs the single `NSEvent` local monitor and runs events through the responder chain                       |
| `Responders.swift`       | Ordered `KeyResponder` implementations (pending-close, tab cycle, command palette, hotkeys)                   |
| `FocusRestoration.swift` | Retries `makeFirstResponder` across run loop ticks until the pane's NSView is in a window                     |
| `RecencyStack.swift`     | Bounded most-recent-first stack of unique IDs (tab/pane focus history)                                        |
| `Notifications.swift`    | Custom `Notification.Name` constants                                                                          |
| `AppCommand.swift`       | Single source of truth for user-invokable actions; palette and Settings render from `AppCommand.allCases`     |
| `AppTerminationState.swift` | `isTerminating` flag so `windowShouldClose` can distinguish user-close (hide) from quit (let close)        |
| `Updater.swift`          | Sparkle wrapper (`Updater.shared`) + `CheckForUpdatesMenuItem` view                                           |

### Views (`Macterm/Views/`)

| File                                   | Purpose                                                                                                 |
| -------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `MainWindow.swift`                     | Main window layout, `WorkspaceView`, `WindowStyler`                                                     |
| `Sidebar.swift`                        | Project/tab list with native `List(selection:)`                                                         |
| `SplitTreeView.swift`                  | Recursive split rendering with draggable dividers                                                       |
| `TerminalPane.swift`                   | `TerminalPane` + `TerminalSurface` (`NSViewRepresentable` borrowing `pane.nsView`) + search bar overlay |
| `Terminal/GhosttyTerminalNSView.swift` | Core terminal NSView — surface, keyboard, mouse, IME                                                    |
| `SearchBar.swift`                      | Terminal search UI                                                                                      |
| `QuickTerminal.swift`                  | Quick terminal `NSPanel`, Carbon global hotkey                                                          |
| `CommandPalette.swift`                 | `Cmd+Shift+P` / `Cmd+P` command palette                                                                 |

### Ghostty Integration (`Macterm/Ghostty/`)

| File                     | Purpose                                           |
| ------------------------ | ------------------------------------------------- |
| `GhosttyApp.swift`       | libghostty init, config, tick loop, color queries |
| `GhosttyCallbacks.swift` | Routes libghostty callbacks to terminal views     |
| `Theme.swift`            | All UI colors derived from ghostty config         |

### Palette (`Macterm/Palette/`)

| File                    | Purpose                                                                                |
| ----------------------- | -------------------------------------------------------------------------------------- |
| `PaletteEngine.swift`   | Fuzzy-scoring engine, section ordering, path-mode dispatch                             |
| `CommandSource.swift`   | Iterates `AppCommand.allCases` to feed action commands into the palette               |
| `ProjectSource.swift`   | Project items (open/rename/delete) for the palette                                     |
| `DirectorySource.swift` | Filesystem path completions when the palette is in path mode                           |

### Settings (`Macterm/Settings/`)

| File                 | Purpose                                                 |
| -------------------- | ------------------------------------------------------- |
| `SettingsView.swift` | Preferences window — font, theme, hotkeys, misc toggles |

### Model (`Macterm/Model/`)

| File                        | Purpose                                                      |
| --------------------------- | ------------------------------------------------------------ |
| `SplitNode.swift`           | Recursive split tree, `Pane`, `SplitBranch`, tree operations |
| `Workspace.swift`           | `TerminalTab`, `Workspace` — tab lifecycle and history       |
| `Project.swift`             | `Project` struct                                             |
| `TerminalSearchState.swift` | Search state with Combine debounce                           |

### Persistence (`Macterm/Persistence/`)

| File                         | Purpose                                                 |
| ---------------------------- | ------------------------------------------------------- |
| `WorkspacePersistence.swift` | Snapshot types, `WorkspaceStore`, `WorkspaceSerializer` |
| `ProjectStore.swift`         | `ProjectStore` — project CRUD + JSON persistence        |
| `FileStorage.swift`          | App Support directory helpers                           |

### Config (`Macterm/Config/`)

| File                  | Purpose                                    |
| --------------------- | ------------------------------------------ |
| `MactermConfig.swift` | Reads/writes `ghostty.conf` in App Support |

### Tests (`MactermTests/`)

Mirror the production tree. Use `@testable import Macterm` and `@MainActor` on test classes. `mise run test` runs the suite locally and on every CI push.

| Path                                         | Covers                                                                              |
| -------------------------------------------- | ----------------------------------------------------------------------------------- |
| `Model/SplitNode*Tests.swift`                | Tree ops, resize, geometry (`paneFrames`, `nearestPane`), rebalance                 |
| `Model/TerminalTabTests.swift`               | Focus history, split/resize/removePane, HV-close regression                         |
| `Model/WorkspaceTests.swift`                 | Tab lifecycle, recency, reorder                                                     |
| `Model/PaneTests.swift`                      | `processTitle` heuristics, `destroySurface` idempotency                             |
| `App/AppStateTests.swift`                    | Integration: splitPane/closePane/focusPaneInDirection via injected `WorkspaceStore` |
| `App/RecencyStackTests.swift`                | Generic stack helper                                                                |
| `App/HotkeysTests.swift`                     | `parseShortcut`, `displayString`, `HotkeyAction` sanity                             |
| `Palette/PaletteEngineTests.swift`           | `fuzzyScore`, engine sections/sort/path-mode                                        |
| `Persistence/WorkspaceSerializerTests.swift` | Snapshot/restore round-trip + on-disk via `WorkspaceStore`                          |
| `Support/TreeBuilder.swift`                  | DSL: `H(pane("a"), V(pane("b"), pane("c")))` → `(SplitNode, [name: UUID])`          |
| `Support/TreeRenderer.swift`                 | Inverse DSL for readable assertions                                                 |

**Testing conventions:**

- One `XxxTests.swift` per production type, mirroring the source path.
- Shared helpers live in `MactermTests/Support/`.
- Tests that need `AppState` or `WorkspaceStore` inject a tempdir file — never touch `~/Library/Application Support/`.
- UI (SwiftUI views, AppKit surfaces, ghostty libghostty bindings) is not unit-tested; coverage targets the model + persistence + palette/hotkey logic.

## Conventions

### Code Style

- **SwiftFormat** + **SwiftLint** enforced. Run `mise run format`, `mise run lint`, and `mise run test` before committing.
- `@MainActor @Observable` on all state classes.
- No `@Published` / `ObservableObject` — use `@Observable` (Swift 5.9+).
- Environment injection: `@Environment(AppState.self)`, not `@EnvironmentObject`.

### Commit Conventions

- **Never add a `Co-Authored-By: Claude` trailer or any AI sign-off** to commits. Commits are authored by the human committer only.
- Subject line focuses on the "why" in 1–2 sentences. Split logically independent changes into separate commits.

### UI Principles

- **Always use native SwiftUI/AppKit components.** Never mimic native behavior with custom implementations. If a native component has a limitation, accept it rather than building a workaround.
- All colors come from `MactermTheme`, which derives from the ghostty theme config. No hardcoded colors.
- The app targets macOS 26 (Tahoe) with liquid glass appearance.

### Terminal Surface Rules

- `GhosttyTerminalNSView` is owned by `Pane`, not SwiftUI. `TerminalSurface.dismantleNSView` is a no-op — never tear down the NSView from a SwiftUI path.
- `pane.destroySurface()` kills the shell process. Only call it when a pane is permanently closed (AppState handles this after the pane leaves the tree).
- `createSurface()` needs a non-zero frame and a window. `TerminalSurface` defers creation via `DispatchQueue.main.async` until the view is attached to a window.
- The `closeSurface` callback from ghostty fires asynchronously. Guard against double-close.
- First-responder handoff after tree reshapes/tab switches must go through `FocusRestoration.restoreFocus(...)` — not a bare `makeFirstResponder`, which races the NSView's window attachment.

### Persistence

- Workspaces saved to `~/Library/Application Support/Macterm/workspaces_v3.json`
- Projects saved to `projects.json` in the same directory
- Ghostty config at `~/.config/Macterm/ghostty.conf` (seeded from `~/.config/ghostty/config` on first launch)
- `Pane` IDs are not preserved across restarts — `restoreNode` creates new `Pane` instances with fresh UUIDs

### Adding a New Action

1. Add a case to `AppCommand` in `AppCommand.swift` with its title, category, and (if rebindable) linked `HotkeyAction`. The palette picks it up automatically via `AppCommand.allCases`.
2. If the command is keyboard-bindable, add the corresponding `HotkeyAction` case to `Hotkeys.swift` with its default shortcut.
3. Add a handler in the appropriate `KeyResponder` in `Responders.swift` (or extend an existing one).
4. The terminal's `isAppShortcut` automatically picks it up via `HotkeyAction.allCases`.
5. Add a test case to `HotkeysTests.swift` if the action introduces new parse/display behavior.

### Adding a New Setting

1. Add UI to `SettingsView.swift` in the appropriate `Section`
2. Use `MactermConfig.shared.updateValue/removeValue` for ghostty config keys
3. Call `GhosttyApp.shared.reloadConfig()` after changes
4. For app-level settings, add a property to `Preferences` (don't read `UserDefaults.standard` directly from views)

## Known Limitations

- **No process persistence** — closing the app kills all shell processes. Recommend tmux/zellij for session persistence.
- **Single window only** — multi-window requires process syncing (tmux-like daemon) which is out of scope.
- **Not code-signed with a Developer ID** — first-launch users must run `xattr -cr /Applications/Macterm.app` to clear the quarantine flag (or install via Homebrew, which strips it automatically). Subsequent auto-updates go through Sparkle and verify an EdDSA signature, so the workaround isn't needed again.
- **Pane IDs not stable across restarts** — view cache entries from previous sessions are orphaned. Fresh views are created on restore.
