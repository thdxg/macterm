<!-- page:
slug: configuration
title: Configuration
nav: Configuration
group: Getting started
description: Point Macterm at your Ghostty config and manage the settings of Macterm.
-->

# Configuration

Macterm reads your existing Ghostty config. It uses the same file in the same places, and you do not convert anything. Your theme, font, palette and keybinds carry over. Every key is in the [Ghostty option reference](https://ghostty.org/docs/config/reference).

```ini title="~/.config/ghostty/config"
theme = catppuccin-mocha
font-family = JetBrains Mono
font-size = 14
```

If you have no config, Macterm uses `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`. If your config is in another place, set the path in **Settings → General → Ghostty Config**. To apply an edit with no restart, run **Reload Ghostty Config** from the command palette.

## Defaults that differ from Ghostty

Macterm has its own defaults for a few keys. Macterm loads them before your config, so a key that you set always wins.

| Key | Macterm default |
| --- | --- |
| `theme` | `"Rose Pine"` |
| `font-size` | `16` |
| `macos-option-as-alt` | `true` |
| `window-padding-x`, `window-padding-y` | `16` |
| `tab-inherit-working-directory` | `false`. New tabs start at the project root. |

The full list is `defaultsBody` in [`MactermConfig.swift`](https://github.com/thdxg/macterm/blob/main/Macterm/Config/MactermConfig.swift).

## Keys Macterm overrides

Macterm draws the window chrome itself. It ignores or forces these keys:

| Key | Set it here instead |
| --- | --- |
| `background-opacity` | Settings → Appearance → Window opacity |
| `background-blur` | Settings → Appearance → Blur |
| titlebar, window-decoration, split-divider and quick-terminal keys | Settings |
| `bell-features = title`, `border` | Not implemented |
| `macos-non-native-fullscreen` | Not implemented. Full screen is always native. |

`background-opacity-cells` works as in Ghostty. All other keys work as the upstream docs describe them. This includes `bell-features = system`, `audio` and `attention` (`attention` puts a badge on the Dock icon with the number of tabs that wait for you), `mouse-scroll-multiplier` and `custom-shader`.

## Keys with no Settings equivalent

| Key | Effect |
| --- | --- |
| `tab-inherit-working-directory` | `false` (the Macterm default) starts new tabs at the project root. `true` uses the directory of the focused pane. |
| `split-inherit-working-directory` | The same, for splits. |
| `focus-follows-mouse` | `true` focuses the pane under the pointer in the active window, as a click on the pane does. It never takes focus from the command palette, the search bar or a rename field. |
| `macos-shortcuts` | Controls access to [Shortcuts](/docs/shortcuts): `ask` (default), `allow` or `deny`. |
| `macos-icon = custom` and `macos-custom-icon` | Replaces the Dock icon. The value is the absolute path to a PNG, JPEG or ICNS file. Macterm ignores other `macos-icon` values. |
| `macos-hidden = always` | Runs Macterm with no Dock icon, no menu bar, and no <kbd>⌘</kbd><kbd>⇥</kbd> entry. See below. |

## Macterm settings

**Macterm → Settings** has the settings for window opacity, blur, sidebar behavior, quick terminal geometry, keymaps and animations.

## Keybinds

Go to **Settings → Keymaps**. Click the keybind of a row. Press the keys that you want, or clear the keybind with the ✕. If rows have the same keys, each row says so.

Each row has two checkboxes. You cannot select both:

- **Pass to TUI** gives the keys to the program in the focused pane. The action does not run. List the programs under **Passthrough Programs** at the top of the tab. Separate them with commas. Use the name that the tab shows.
- **Global** registers the keys for the whole system, so the action runs when another app is in front. Macterm does not need the Accessibility permission. If another app already uses the keys, the row says so.

## Open files in your terminal editor

Macterm can open text files in a terminal editor such as Helix or Neovim. macOS cannot make such an editor a default app on its own.

1. In Finder, select a file and choose **File → Get Info**. Under **Open with**, select **Macterm**. Click **Change All**. Do this for each file type that you want. If Macterm is not in the list, it does not register for that file type. For a single file, use **Open With → Other…**.
2. Set `$EDITOR` in your shell config. Set `$VISUAL` if you want it to win over `$EDITOR`. For example, `$env.EDITOR = "hx"` in nu or `export EDITOR=nvim` in zsh. If you set neither, files open in `vi`.
3. In **Settings → General → Text Files**, choose **Open in**: **New split** (next to the current pane, along its longer side) or **New tab**.

You can double-click such a file, open it with **Open With → Macterm**, or run `open -a Macterm file.rs`. In each case, the file opens in the project that contains it. If no project contains it, Macterm creates a project for the folder of the file.

<kbd>⌘</kbd>-click a path in a pane to open it with its default app. Paths such as `src/main.rs:42:7` work too. Compilers and test runners print paths in this form. When Macterm is the default app, the file opens at that line. The editor gets `+42` before the path. The editors vi, Vim, Neovim, Helix, Kakoune, Emacs, nano and micro all understand this. Other apps cannot receive a line, so they get only the file.

When you quit the editor, its split or tab closes. Paths that a [remote project](/docs/remote-projects) prints do not open in the editor, because the file is on the host.

## Project colors

Set a color from the sidebar context menu of a project (**Color**) or in **Settings → Projects**. The color tints the sidebar icon of the project and the icons of its tabs. **Settings → Appearance → Auto-assign project colors** (off by default) gives each new project a color by itself.

## Animations

Go to **Settings → Animations**. Smooth scrolling and split animations are on. The cursor effects are off.

| Toggle | Effect |
| --- | --- |
| **Smooth scrolling** | Trackpad scrolling and divider drags move by pixels, not by whole rows. Full-screen programs that scroll a region of the screen slide too (`less`, for example). Programs that redraw every row still move by rows. |
| **Snap to whole row** | Works with smooth scrolling. Scrolling moves one whole row at a time, and each row slides into place, as `less` scrolls. It never stops between rows. Off by default. |
| **Animate splits** | Panes slide in and out of the split layout. It turns off by itself when Reduce Motion is on. |
| **Smooth cursor** | The cursor glides between positions. The text that the cursor passes over has the cursor color, only as far as the cursor covers it. Programs that draw their own cursor (a second cursor in Helix, for example) still move it by cells. |
| **Cursor trail** | A fading streak follows the cursor on larger moves. It is under the text. If you use a community trail shader, turn it off. Otherwise you see two trails. |

## Running without a Dock icon

Set `macos-hidden = always` to run Macterm as an accessory app. Use it to work from the [quick terminal](/docs/quick-terminal). The window, the sidebar, the sessions and every keybind keep working. `macterm window focus` still brings a window forward.

> An accessory app has no menu bar. **Settings, Quit, About and Check for Updates lose their keyboard route.** Set your Macterm preferences before you turn this on. To go back, set `macos-hidden = never` and reload.
