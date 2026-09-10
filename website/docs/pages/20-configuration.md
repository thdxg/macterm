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

`bell-features` works too, with one difference. `system` (the alert beep), `audio` (your `bell-audio-path` and `bell-audio-volume`), and `attention` are all honored; `title` and `border` are not, since Macterm draws neither a Ghostty tab title nor a surface border. Under `attention`, a bell bounces the Dock icon as in Ghostty and badges the Dock tile with the number of **tabs** waiting on you — Ghostty counts windows, but a Macterm tab is what you go and look at. A tab counts once however many of its panes rang, the badge tops out at `99+`, and it clears as soon as you are looking at the tab: selecting it, clicking or typing in one of its panes, or switching back to Macterm while it is showing.

Ghostty's custom app icon carries over too: `macos-icon = custom` with `macos-custom-icon = /path/to/icon.png` (PNG, JPEG or ICNS; `~` expands, the path must be absolute) replaces Macterm's Dock and app-switcher icon, applied at launch and on every config reload, and reverting to the bundled icon when the key is unset or the file is missing or unreadable. Macterm sets it on the running app, so the bundle's icon in Finder stays Macterm's own. The rest of Ghostty's `macos-icon` values — the artist variants (`blueprint`, `xray`, …) and `custom-style` with its `macos-icon-ghost-color`, `macos-icon-screen-color` and `macos-icon-frame` companions — are Ghostty-brand artwork with no Macterm equivalent and are ignored.

Give a project a **color** from its sidebar context menu (Color) or from **Settings → Projects**. The color tints the project's icon in the sidebar and the icon on each of its tabs, so a glance says which project a tab belongs to. It is only ever a tint on an icon, so with the sidebar icon preference set to None a project row has nothing to tint; a tab row still shows the color on an AI agent logo or a status indicator, the glyphs that setting doesn't suppress. The eight colors are fixed system colors, so a tag always looks like its name and no two tags collide. **Settings → Appearance → Auto-assign project colors** (off by default) gives each new project the least-used color automatically; it never changes projects you already have.

> The `ssh-env` and `ssh-terminfo` shell-integration features work out of the box — Macterm serves them natively (via `macterm ssh`), no Ghostty.app needed. The `path` feature is disabled: Macterm ships no `ghostty` CLI to put on your PATH (the bundled `macterm` CLI is already there).
