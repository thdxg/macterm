<h1 align="center">
  <img src="./assets/icon.png" width="128" />
  <br />
  Macterm
</h1>

<p align="center">
  A native macOS terminal with vertical tabs and persistent multiplexing, built on libghostty
</p>

<p align="center">
  <a href="https://github.com/thdxg/macterm/releases/latest">
    <img src="https://img.shields.io/github/v/release/thdxg/macterm?label=version&color=blue" alt="Latest version" />
  </a>
  <a href="https://github.com/thdxg/macterm/releases">
    <img src="https://img.shields.io/github/downloads/thdxg/macterm/total" alt="Total downloads" />
  </a>
  <a href="https://github.com/thdxg/macterm/actions/workflows/checks.yml">
    <img src="https://img.shields.io/github/actions/workflow/status/thdxg/macterm/checks.yml?branch=main&label=checks" alt="CI status" />
  </a>
  <a href="https://github.com/thdxg/macterm/blob/main/LICENSE">
    <img src="https://img.shields.io/github/license/thdxg/macterm?color=lightgrey" alt="License" />
  </a>
  <img src="https://img.shields.io/badge/macOS-26%2B-black?logo=apple" alt="macOS 26+" />
</p>

![screenshot](./assets/screenshot.png)

## Features

- **Vertical Project Sidebar**: Native macOS sidebar for organizing projects and tabs vertically.
- **Persistent Multiplexing**: Projects, tabs, and panes are saved and restored automatically on relaunch.
- **Ghostty Config Compatibility**: Macterm reads your existing `~/.config/ghostty/config`. Theme, font, palette, keybinds — all of it just works.
- **Keyboard-first Navigation**: Customizable keybinds for navigating projects, tabs, and panes.
- **Command Palette**: Versatile command palette to interact with multiplexing and manage projects
- **Quick terminal**: Global terminal accessible from anywhere with a hotkey.
- **Declarative Layouts**: Commit a `.macterm/layout.yaml` describing each project's tabs, splits, and the process every pane runs; apply or save it from the command palette.

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

Macterm's window appearance is highly customizable and hot-reloaded. Drop the
opacity below 100% and choose between a classic Gaussian **Background Blur** or
the macOS 26 **Liquid Glass** material — in two styles, frostier **Regular** or
more transparent **Clear** — all in **Settings → General → Window**.

https://github.com/user-attachments/assets/1486ed55-e653-43ce-98aa-232a61d234a7

## Configuration

Macterm reads your `~/.config/ghostty/config` on launch — themes, fonts, palettes, keybinds, and everything else Ghostty supports works the same here. See the [Ghostty option reference](https://ghostty.org/docs/config/reference) for the full list of available settings. If your config is elsewhere, set the path in **Settings → General → Ghostty Config**.

Macterm ships a thin defaults layer on top of Ghostty's own defaults. These are the values that differ:

| Option                                                                                 | Macterm default | Ghostty default |
| -------------------------------------------------------------------------------------- | --------------- | --------------- |
| [`theme`](https://ghostty.org/docs/config/reference#theme)                             | `Rose Pine`     | _(none)_        |
| [`font-size`](https://ghostty.org/docs/config/reference#font-size)                     | `16`            | `12`            |
| [`window-padding-x`](https://ghostty.org/docs/config/reference#window-padding-x)       | `16`            | `2`             |
| [`window-padding-y`](https://ghostty.org/docs/config/reference#window-padding-y)       | `16`            | `2`             |
| [`macos-option-as-alt`](https://ghostty.org/docs/config/reference#macos-option-as-alt) | `true`          | `false`         |

Add any of these to your Ghostty config to override them. Macterm-specific settings (window opacity, blur style, quick terminal size, hotkeys) live in **Macterm → Settings**.

A few settings are overridden because Macterm handles that chrome itself: `background-opacity` and `background-blur` are forced to `0` (use **Settings → General → Window** instead), and titlebar, window decoration, split-divider, and quick-terminal settings are ignored.

Ghostty keybinds work normally unless they conflict with a Macterm shortcut — on conflict, Macterm wins. Every Macterm shortcut is rebindable in **Settings → Keymaps**. Note that Ghostty app-level actions (`new_split`, `new_tab`, etc.) do nothing in Macterm; use Macterm's own keybinds for those.

Shell integration works standalone — no Ghostty.app needed. The one exception is `ssh-env`, `ssh-terminfo`, and `path` features, which require the `ghostty` CLI; install Ghostty.app to enable them.

## Project Layouts

You can declare a project's tabs, split layout, and the process each pane runs in a committable `.macterm/layout.yaml` at the project root. When you first open a project this session and it has a layout file (with no restored session), Macterm applies it automatically. You can also run **Save layout** from the command palette to write your current workspace out, or **Apply layout** to load the file back on demand.

```yaml
name: "MyApp" # the project this layout is for (optional)
shell: /bin/zsh # optional default shell for every pane
tabs:
  - name: "Dev"
    layout:
      split: horizontal # horizontal | vertical
      ratio: 0.6 # divider position, 0–1 (defaults to 0.5)
      first:
        cwd: "./api" # project-relative working directory
        run: "npm run dev" # typed into the pane's shell on launch
      second:
        split: vertical
        first: { cwd: "./api", run: "npm test -- --watch" }
        second: {} # plain shell, no command
```

A pane's `run` is typed into a normal shell (so you keep the prompt and history, and the pane survives when the command exits). The shell is the per-pane `shell`, else the file-level `shell`, else the one from your Ghostty config.

**Save** records the project `name:`, each tab's split layout, every pane's working directory, and the command each pane is currently running (its foreground process — so a pane running `npm run dev` is saved with that `run:`, a pane idle at a prompt gets none). The captured command is the resolved process invocation (e.g. `node …/npm-cli.js run dev`), which you can tidy by hand. Save does not record `shell:` — set that yourself if a pane needs a specific shell. If you apply a layout whose `name:` doesn't match the current project, Macterm asks you to confirm first.

**Apply** reconciles the live workspace toward the file with minimal disruption: a pane already running the declared `run` in the same directory is kept (only resized if its split ratio changed), and only panes that genuinely deviate are restarted or closed. When an apply would terminate any pane, Macterm asks for confirmation first. An invalid layout file is reported and never applied.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, build, and PR guidelines.

## License

MIT
