<!-- page:
slug: configuration
title: Configuration
nav: Configuration
group: Getting started
description: Point Macterm at your Ghostty config and manage Macterm-specific settings.
-->

# Configuration

Macterm follows Ghostty's macOS config precedence on launch: Application Support `config.ghostty`, Application Support legacy `config`, XDG `config.ghostty`, then XDG legacy `config`. It respects `$XDG_CONFIG_HOME`; when unset, XDG defaults to `~/.config`. With no existing config, Macterm uses `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`. Themes, fonts, palettes, keybinds, and everything else Ghostty supports work the same here. If your config lives elsewhere, set the path in **Settings → General → Ghostty Config**.

Macterm-specific settings — window opacity, blur style, sidebar behavior, quick-terminal size, and hotkeys — live in **Macterm → Settings**. When hidden-sidebar peek is enabled, the sidebar can either slide out as a normal split-view column or appear as a rounded overlay without resizing the terminal. The overlay uses Liquid Glass on macOS 26+ and a native material on older systems. A few Ghostty keys are overridden because Macterm owns that chrome: the terminal never paints its own default background (Macterm composites the window translucency itself, so set opacity in Settings), `background-opacity` is kept in sync with the Settings window opacity, `background-blur` is forced to `0`, and titlebar, window-decoration, split-divider, and quick-terminal settings are ignored. `background-opacity-cells` works as in Ghostty: enable it in your config and TUI-painted cell backgrounds (helix, nvim, btop themes) follow the window opacity instead of staying fully opaque.

Ghostty's custom app icon carries over too: `macos-icon = custom` with `macos-custom-icon = /path/to/icon.png` (PNG, JPEG or ICNS; `~` expands, the path must be absolute) replaces Macterm's Dock and app-switcher icon, applied at launch and on every config reload, and reverting to the bundled icon when the key is unset or the file is missing or unreadable. Macterm sets it on the running app, so the bundle's icon in Finder stays Macterm's own. The rest of Ghostty's `macos-icon` values — the artist variants (`blueprint`, `xray`, …) and `custom-style` with its `macos-icon-ghost-color`, `macos-icon-screen-color` and `macos-icon-frame` companions — are Ghostty-brand artwork with no Macterm equivalent and are ignored.

## Keybinds

Every Macterm action is rebindable in **Settings → Keymaps**: click a row's keybind, press the chord you want, or clear it with the ✕ to unbind. Rows that share a chord say so, so a conflict is visible before you go looking for it.

Two per-row checkboxes change *where* a chord applies.

**Pass to TUI** hands the chord to the program running in the focused pane instead of running the action — so <kbd>⌃H</kbd> bound to Focus Left can still move nvim's own splits while you are inside nvim, and move Macterm's panes everywhere else. It only yields to programs you name in **Passthrough Programs** at the top of the tab (match the name the tab shows, separated by commas); anything else you run keeps getting the action.

**Global** registers the chord system-wide, so the action runs while another app is frontmost — press it from your browser and Macterm comes forward with a new tab, a new split, or the command palette open. It needs no Accessibility permission. Three things follow from a chord being global: it belongs to Macterm *everywhere*, so no other app can see it; the action it runs is the app-level one, not the quick terminal's version of it; and it cannot also pass through to a program, so the two checkboxes are mutually exclusive. If the chord is already taken, the row says so and the keybind keeps working inside Macterm — pick another and the message clears. The quick-terminal hotkey is global by definition, so its checkbox is ticked and fixed.

Give a project a **color** from its sidebar context menu (Color) or from **Settings → Projects**. The color tints the project's icon in the sidebar and the icon on each of its tabs, so a glance says which project a tab belongs to. It is only ever a tint on an icon, so with the sidebar icon preference set to None a project row has nothing to tint; a tab row still shows the color on an AI agent logo or a status indicator, the glyphs that setting doesn't suppress. The eight colors are fixed system colors, so a tag always looks like its name and no two tags collide. **Settings → Appearance → Auto-assign project colors** (off by default) gives each new project the least-used color automatically; it never changes projects you already have.

## Running without a Dock icon

`macos-hidden = always` in your Ghostty config runs Macterm as an accessory app: no Dock icon, no menu bar, and no entry in <kbd>⌘</kbd><kbd>⇥</kbd>. It is for working out of the [quick terminal](/docs/quick-terminal) — the hotkey still drops the panel over whatever you are in, and the panel takes your typing without bringing Macterm forward, exactly as before. `never` (the default) keeps the ordinary app. The value is read live, so **Reload Ghostty Config** moves it either way without a restart.

Macterm still opens its window, unlike Ghostty in the same mode — the window is where the keymap and the `macterm` CLI attach — so nothing else changes: the sidebar, splits, sessions, projects and every keybinding work as they do normally, and `macterm window focus` or `macterm window new` brings a window forward and focused even from another terminal.

What you give up is everything that lives in the menu bar, because an accessory app has none:

- **Settings, Quit, About and Check for Updates have no keyboard route.** <kbd>⌘</kbd><kbd>,</kbd> and <kbd>⌘</kbd><kbd>Q</kbd> are menu-bar shortcuts, and Macterm's Settings window is only reachable from that menu. Set your Macterm preferences (opacity, hotkeys, quick-terminal size) *before* switching the key on; to get back to them, set `macos-hidden = never` and reload.
- Ghostty documents one more consequence of the same policy that we have not measured here: keyboard layout changes stop being picked up automatically.

Everything bound to a key still works: keybindings go through Macterm's own router, not the menu bar, so the command palette, tabs, splits and the quick terminal are unaffected.

> The `ssh-env` and `ssh-terminfo` shell-integration features work out of the box — Macterm serves them natively (via `macterm ssh`), no Ghostty.app needed. The `path` feature is disabled: Macterm ships no `ghostty` CLI to put on your PATH (the bundled `macterm` CLI is already there).
