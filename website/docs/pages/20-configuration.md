<!-- page:
slug: configuration
title: Configuration
nav: Configuration
group: Getting started
description: Point Macterm at your Ghostty config and manage Macterm-specific settings.
-->

# Configuration

Macterm reads your existing Ghostty config — same file, same locations, no conversion. Theme, font, palette, and keybinds all carry over. Every key is in the [Ghostty option reference](https://ghostty.org/docs/config/reference).

```ini title="~/.config/ghostty/config"
theme = catppuccin-mocha
font-family = JetBrains Mono
font-size = 14
```

With no existing config, Macterm uses `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`. If yours lives elsewhere, set the path in **Settings → General → Ghostty Config**. Run **Reload Ghostty Config** from the command palette to apply an edit without restarting.

## Defaults that differ from Ghostty

Macterm ships its own defaults for a few keys. They load before your config, so setting any of them yourself wins.

| Key | Macterm default |
| --- | --- |
| `theme` | `"Rose Pine"` |
| `font-size` | `16` |
| `macos-option-as-alt` | `true` |
| `window-padding-x`, `window-padding-y` | `16` |
| `tab-inherit-working-directory` | `false` — new tabs start at the project root |

The source of truth is `defaultsBody` in [`MactermConfig.swift`](https://github.com/thdxg/macterm/blob/main/Macterm/Config/MactermConfig.swift).

## Keys Macterm overrides

Window chrome Macterm draws itself, so these are ignored or forced:

| Key | Set it here instead |
| --- | --- |
| `background-opacity` | Settings → Appearance → Window opacity |
| `background-blur` | Settings → Appearance → Blur |
| titlebar, window-decoration, split-divider, quick-terminal keys | Settings |
| `bell-features = title`, `border` | not implemented |
| `macos-non-native-fullscreen` | not implemented — full screen is always native |

`background-opacity-cells` works as in Ghostty. Everything else — `bell-features = system`, `audio`, `attention` (which badges the Dock with the number of tabs waiting on you), `mouse-scroll-multiplier`, `custom-shader` — behaves as documented upstream.

## Keys with no Settings equivalent

| Key | Effect |
| --- | --- |
| `tab-inherit-working-directory` | `false` (Macterm's default) starts new tabs at the project root; `true` uses the focused pane's directory. |
| `split-inherit-working-directory` | Same, for splits. |
| `macos-shortcuts` | Gates [Shortcuts](/docs/shortcuts): `ask` (default), `allow`, `deny`. |
| `macos-icon = custom` + `macos-custom-icon` | Replaces the Dock icon. Absolute path to a PNG, JPEG, or ICNS. Other `macos-icon` values are ignored. |
| `macos-hidden = always` | Runs Macterm with no Dock icon, no menu bar, and no <kbd>⌘</kbd><kbd>⇥</kbd> entry. See below. |

## Macterm settings

**Macterm → Settings** owns window opacity, blur, sidebar behavior, quick-terminal geometry, keymaps, and animations.

## Keybinds

**Settings → Keymaps**. Click a row's keybind, press the chord you want, or clear it with the ✕. Rows sharing a chord say so.

Two per-row checkboxes, mutually exclusive:

- **Pass to TUI** — hands the chord to the program in the focused pane instead of running the action. List the programs under **Passthrough Programs** at the top of the tab, comma-separated, matching the name the tab shows.
- **Global** — registers the chord system-wide, so the action runs while another app is frontmost. No Accessibility permission needed. If the chord is already taken, the row says so.

## Open files in your terminal editor

Macterm can open text files in a terminal editor such as Helix or Neovim, which macOS can't make a default app on its own.

1. In Finder, select a file, choose **File → Get Info**, pick **Macterm** under **Open with**, and click **Change All**. Repeat for each file type you want. If Macterm isn't in the list, it doesn't register for that file type; use **Open With → Other…** for a one-off.
2. Set `$EDITOR` (or `$VISUAL`, which wins) in your shell config, e.g. `$env.EDITOR = "hx"` in nu or `export EDITOR=nvim` in zsh. Without either, files open in `vi`.
3. In **Settings → General → Text Files**, choose **Open in**: **New split** (beside the current pane, along its longer side) or **New tab**.

Double-clicking such a file, opening it with **Open With → Macterm**, or `open -a Macterm file.rs` opens it in the project that contains it. If no project does, Macterm creates one for the file's folder.

<kbd>⌘</kbd>-click a path in a pane to open it with its default app. Paths like `src/main.rs:42:7`, as printed by compilers and test runners, work too. When Macterm is the default app, the file opens at that line: the editor gets `+42` before the path, which vi, Vim, Neovim, Helix, Kakoune, Emacs, nano and micro all understand. Other apps can't be told a line, so they get just the file.

Quitting the editor closes its split or tab. Paths printed in a [remote project](/docs/remote-projects) don't open in the editor, since the file is on the host.

## Project colors

Set a color from a project's sidebar context menu (**Color**) or **Settings → Projects**. It tints the project's sidebar icon and its tabs' icons. **Settings → Appearance → Auto-assign project colors** (off by default) colors each new project automatically.

## Animations

**Settings → Animations**. Smooth scrolling and split animations are on; the cursor effects are off.

| Toggle | Effect |
| --- | --- |
| **Smooth scrolling** | Trackpad scrolling and divider drags move by pixels instead of whole rows. Full-screen programs that scroll a region of the screen (`less`, for one) slide too; ones that redraw every row still move by rows. |
| **Animate splits** | Panes slide in and out of the split layout. Off automatically under Reduce Motion. |
| **Smooth cursor** | The cursor glides between positions. Sets `cursor-opacity = 0` while on. |
| **Cursor trail** | A fading streak follows the cursor. Turn off any community trail shader, or you'll see two. |

## Running without a Dock icon

Set `macos-hidden = always` to run Macterm as an accessory app — for working out of the [quick terminal](/docs/quick-terminal). The window, sidebar, sessions, and every keybinding keep working; `macterm window focus` still brings a window forward.

> An accessory app has no menu bar, so **Settings, Quit, About and Check for Updates lose their keyboard route**. Set your Macterm preferences before switching it on. To get back, set `macos-hidden = never` and reload.
