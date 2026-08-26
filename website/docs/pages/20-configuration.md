<!-- page:
slug: configuration
title: Configuration
nav: Configuration
group: Getting started
description: Point Macterm at your Ghostty config and manage Macterm-specific settings.
-->

# Configuration

Macterm follows Ghostty's macOS config precedence on launch: Application Support `config.ghostty`, Application Support legacy `config`, XDG `config.ghostty`, then XDG legacy `config`. It respects `$XDG_CONFIG_HOME`; when unset, XDG defaults to `~/.config`. With no existing config, Macterm uses `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`. Themes, fonts, palettes, keybinds, and everything else Ghostty supports work the same here. If your config lives elsewhere, set the path in **Settings → General → Ghostty Config**.

Macterm-specific settings — window opacity, blur style, quick-terminal size, and hotkeys — live in **Macterm → Settings**. A few Ghostty keys are overridden because Macterm owns that chrome: the terminal never paints its own default background (Macterm composites the window translucency itself, so set opacity in Settings), `background-opacity` is kept in sync with the Settings window opacity, `background-blur` is forced to `0`, and titlebar, window-decoration, split-divider, and quick-terminal settings are ignored. `background-opacity-cells` works as in Ghostty: enable it in your config and TUI-painted cell backgrounds (helix, nvim, btop themes) follow the window opacity instead of staying fully opaque.

> The `ssh-env` and `ssh-terminfo` shell-integration features work out of the box — Macterm serves them natively (via `macterm ssh`), no Ghostty.app needed. The `path` feature is disabled: Macterm ships no `ghostty` CLI to put on your PATH (the bundled `macterm` CLI is already there).
