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

Give a project a **color** from its sidebar context menu (Color) or from **Settings → Projects**. The color tints the project's icon in the sidebar and the icon on each of its tabs, so a glance says which project a tab belongs to. It is only ever a tint on an icon, so with the sidebar icon preference set to None there is nothing to tint and tags don't show. The eight colors are fixed system colors, so a tag always looks like its name and no two tags collide. **Settings → Appearance → Auto-assign project colors** (off by default) gives each new project the least-used color automatically; it never changes projects you already have.

> The `ssh-env` and `ssh-terminfo` shell-integration features work out of the box — Macterm serves them natively (via `macterm ssh`), no Ghostty.app needed. The `path` feature is disabled: Macterm ships no `ghostty` CLI to put on your PATH (the bundled `macterm` CLI is already there).
