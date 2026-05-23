<h1 align="center">
  <img src="./assets/icon.png" width="128" />
  <br />
  Macterm
</h1>

<p align="center">
  A native macOS terminal with vertical tabs and persistent multiplexing, built on libghostty
</p>

![screenshot](./assets/screenshot.png)

## Features

- **Vertical Project Sidebar**: Native macOS sidebar for organizing projects and tabs vertically.
- **Split Panes**: Unlimited horizontal and vertical splits, with optional auto-tiling.
- **Persistence**: Projects, tabs, and panes are saved and restored automatically.
- **Quick terminal**: Global terminal accessible from anywhere.
- **Configurable via Ghostty config**: Macterm reads your existing `~/.config/ghostty/config`. Theme, font, palette, keybinds — all of it just works.
- **Command Palette**: Versatile command palette to interact with multiplexing (open, delete, and search projects)

## Install

### Homebrew

```bash
brew install --cask thdxg/tap/macterm
```

The cask strips the Gatekeeper quarantine xattr on install, so the app launches without any extra prompts. Updates are delivered via Sparkle inside the app.

### From Releases

Download the latest `.dmg` from [Releases](https://github.com/thdxg/macterm/releases), open it, and drag Macterm to Applications.

Since the app isn't signed with an Apple Developer certificate, macOS will block it on first launch. To allow the app to launch, run this command in another terminal (you only need to do this once):

```bash
xattr -cr /Applications/Macterm.app
```

## Demos

### Keybinds

Macterm is very keyboard-oriented, so you can perform the majority of actions without lifting your hand.

https://github.com/user-attachments/assets/42b2dce8-1d6d-41d6-a4c8-2e0c1339810b

### Window Opacity & Blur

Macterm's window appearance is highly customizable and hot-reloaded.

https://github.com/user-attachments/assets/1486ed55-e653-43ce-98aa-232a61d234a7

## For Ghostty Users

Macterm uses libghostty as its terminal engine and reads your existing `~/.config/ghostty/config` on launch. Themes, fonts, palettes, keybinds, scrollback, cursor style, shell integration, mouse behavior — everything Ghostty supports works the same in Macterm.

If your config lives somewhere else, point Macterm at it in **Settings → General → Ghostty Config**. Click **Reload** there after saving external edits — Macterm doesn't auto-detect them.

### What's different from Ghostty.app

A handful of settings either don't apply or are overridden, because Macterm renders some of the chrome itself instead of letting Ghostty do it. If you have these in your Ghostty config, they'll be parsed without errors but won't change anything in Macterm:

| Setting                                                         | Status          | Why                                                                                                                           |
| --------------------------------------------------------------- | --------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `background-opacity`                                            | Overridden to 0 | Macterm composites window translucency at the AppKit level. Use **Settings → General → Window → Background Opacity** instead. |
| `background-blur`                                               | Overridden to 0 | Same reason. Use the **Background Blur** slider in Settings.                                                                  |
| `unfocused-split-opacity`                                       | Ignored         | Macterm draws its own dim overlay on unfocused panes.                                                                         |
| `split-divider-color`                                           | Ignored         | Divider color comes from the theme's foreground.                                                                              |
| `window-padding-color`                                          | Ignored         | Padding follows the SwiftUI background stack.                                                                                 |
| `macos-titlebar-*`, `macos-window-buttons`, `window-decoration` | Ignored         | Macterm has its own titlebar implementation.                                                                                  |
| `quick-terminal-*` family                                       | Ignored         | Macterm has its own quick terminal. Size lives in **Settings → Quick Terminal**.                                              |

Macterm-specific settings (window opacity/blur, quick terminal dimensions, hotkeys, auto-tile) live in **Macterm → Settings**. Everything else belongs in your Ghostty config.

### Keybinds

Most of your `keybind = ...` lines in Ghostty config work the same as in Ghostty.app. The one rule to know: **on conflict, Macterm wins.** If a keystroke matches one of Macterm's app-level shortcuts (new tab, splits, focus moves, command palette, etc.), Macterm handles it and Ghostty never sees the event. If it doesn't conflict, the keystroke flows through to libghostty and your Ghostty `keybind` fires normally.

Every conflicting combo is rebindable in **Settings → Keymaps**, so if you'd rather a particular shortcut belong to your Ghostty config, clear or remap it there.

One caveat: Ghostty keybinds that drive _app-level_ actions (`new_split`, `new_tab`, `goto_tab`, `goto_split`, etc.) currently do nothing in Macterm — Macterm only triggers those actions through its own keybinds in **Settings → Keymaps**. Terminal-level Ghostty bindings (copy/paste, scroll, font size, etc.) work normally.

### First-launch defaults

If you don't have a `~/.config/ghostty/config`, Macterm starts with the Rose Pine theme at 16pt, 16px window padding, and `macos-option-as-alt = true` (so Option+letter sends Alt to your shell instead of typing special characters). Everything else falls through to Ghostty's own defaults. Any of these can be overridden by adding the corresponding line to your Ghostty config.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, build, and PR guidelines.

## License

MIT
