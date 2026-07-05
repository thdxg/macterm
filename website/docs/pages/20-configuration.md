<!-- page:
slug: configuration
title: Configuration
nav: Configuration
group: Getting started
description: Point Macterm at your Ghostty config and manage Macterm-specific settings.
-->

# Configuration

Macterm reads your `~/.config/ghostty/config` on launch — themes, fonts, palettes, keybinds, and everything else Ghostty supports work the same here. If your config lives elsewhere, set the path in **Settings → General → Ghostty Config**.

Macterm-specific settings — window opacity, blur style, quick-terminal size, and hotkeys — live in **Macterm → Settings**. A few Ghostty keys are overridden because Macterm owns that chrome: `background-opacity` and `background-blur` are forced to `0` (use Settings instead), and titlebar, window-decoration, split-divider, and quick-terminal settings are ignored.

> The `ssh-env`, `ssh-terminfo`, and `path` features require the `ghostty` CLI — install Ghostty.app to enable them.
