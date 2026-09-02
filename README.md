<h1 align="center">
  <img src="./assets/icon.png" width="128" />
  <br />
  Macterm
</h1>

<p align="center">
  A macOS terminal with session persistence, smart multiplexing, and native UI. Built on libghostty.

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
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+" />
</p>

<p align="center">
  <a href="https://macterm.thdxg.dev/docs/"><b>Documentation</b></a> ·
  <a href="https://macterm.thdxg.dev"><b>Website</b></a> ·
  <a href="https://github.com/thdxg/macterm/releases"><b>Releases</b></a>
</p>

![Macterm's vertical project sidebar beside an editor and shell split](./assets/screenshot-1.png)

_Projects and their tabs stack vertically in a native sidebar, with pinned tabs kept above them._

![A full-window TUI with the sidebar hidden](./assets/screenshot-2.png)

_Hide the sidebar to give a TUI the whole window; the background adapts to the colors the program paints._

![The command palette open over a split layout](./assets/screenshot-3.png)

_The command palette (⌘P) jumps to a project, switches tabs, or runs any action._

## Features

- **Session persistence** \
  Quitting detaches your shells instead of killing them; relaunching brings them back with scrollback and running processes intact.
- **Multiplexing** \
  Drag a pane onto another to join them, or separate one into its own tab — by drag or by keybind. Projects, tabs, and split layouts are saved and restored on relaunch.
- **Remote projects** \
  Open a directory on another machine over SSH. Your shells keep running there, surviving quits, dropped connections, and even a local reboot.
- **Vertical project sidebar** \
  Organize projects and their tabs in a native macOS sidebar, stacked vertically where there's room to read them.
- **Pinned tabs** \
  Pin a tab above your projects to keep it running: it starts on every launch, and restores itself with its command if the session dies.
- **Command palette** \
  Press <kbd>⌘P</kbd> to split panes, switch projects, or open a directory. Every action is a keystroke away, and each row shows its keybind.
- **Declarative layouts** \
  Describe a project's tabs, splits, and per-pane commands in YAML; Macterm builds the workspace from it on open.
- **Control CLI** \
  A bundled `macterm` command drives the running app, so scripts and AI agents can spawn panes, run commands, and script layouts.
- **Quick terminal** \
  A global drop-down terminal on a hotkey (<kbd>⌃`</kbd>), for scratch work from anywhere.
- **Adaptive background** \
  The window picks up the background color the running program paints. A full-screen TUI tints the whole window to match; in a split, each pane takes its own.
- **Ghostty compatibility** \
  Reads your existing Ghostty config. Theme, font, keybinds: all of it just works.

## Install

### Homebrew

```bash
brew install --cask thdxg/tap/macterm
```

The cask strips the Gatekeeper quarantine attribute on install, so the app launches without extra prompts.

### From Releases

Download the latest `.dmg` from [Releases](https://github.com/thdxg/macterm/releases), open it, and drag Macterm to Applications. Since the app isn't signed with an Apple Developer certificate, clear the quarantine flag once:

```bash
xattr -cr /Applications/Macterm.app
```

Sparkle handles updates from there, verifying an EdDSA signature on each one — so you won't need `xattr` again.

## Documentation

Full guides live at **[macterm.thdxg.dev/docs](https://macterm.thdxg.dev/docs/)**:

- [Installation](https://macterm.thdxg.dev/docs/install) and [Configuration](https://macterm.thdxg.dev/docs/configuration)
- [Command palette](https://macterm.thdxg.dev/docs/command-palette) and [Quick terminal](https://macterm.thdxg.dev/docs/quick-terminal)
- [Declarative layouts](https://macterm.thdxg.dev/docs/declarative-layouts), [Pinned tabs](https://macterm.thdxg.dev/docs/pinned-tabs), [Session persistence](https://macterm.thdxg.dev/docs/session-persistence), and [Remote projects](https://macterm.thdxg.dev/docs/remote-projects)
- [The `macterm` CLI](https://macterm.thdxg.dev/docs/cli)

### Cookbook

The [**Cookbook**](https://macterm.thdxg.dev/docs/cookbook) collects workflows and recipes from the community — the layouts, keybinds, and scripts people actually run to get more out of Macterm. Three to start with: [one <kbd>⌃hjkl</kbd> chord that moves between nvim's splits *and* Macterm's panes](https://github.com/thdxg/macterm/discussions/217), [driving an interactive program from a script](https://github.com/thdxg/macterm/discussions/218), and [giving a coding agent control of Macterm](https://github.com/thdxg/macterm/discussions/219).

Got a recipe of your own? [Start a Cookbook topic](https://github.com/thdxg/macterm/discussions/new?category=cookbook) — anyone can post, and anyone can borrow.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, build, and PR guidelines.

## License

MIT
