<h1 align="center">
  <img src="./assets/icon.png" width="128" />
  <br />
  Macterm
</h1>

<p align="center">
  A native macOS terminal with a vertical project sidebar and persistent multiplexing, built on libghostty
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

![screenshot](./assets/screenshot.png)

## Features

- **Persistent multiplexing** — projects, tabs, and split panes are saved and restored on relaunch. Shells run under a bundled [zmx](https://github.com/neurosnap/zmx) session, so quitting detaches and relaunching reattaches every pane with its scrollback and running processes intact.
- **Remote projects** — open a directory on another machine over SSH. Each pane is a persistent session *on the host*, so your shells survive quits, dropped connections, and even a local reboot.
- **Vertical project sidebar** — organize projects and their tabs in a native macOS sidebar, stacked vertically where there's room to read them.
- **Command palette** — press <kbd>⌘P</kbd> to split panes, switch projects, or open a directory. Every action is a keystroke away, and each row shows its keybind.
- **Declarative layouts** — describe a project's tabs, splits, and per-pane commands in YAML; Macterm builds the workspace from it on open.
- **Control CLI** — a bundled `macterm` command drives the running app over a local socket, so scripts and AI agents can spawn panes, run commands, and script layouts.
- **Quick terminal** — a global drop-down terminal on a hotkey (<kbd>⌃`</kbd>), for scratch work from anywhere.
- **Ghostty compatibility** — reads your existing `~/.config/ghostty/config`. Theme, font, keybinds — all of it just works.

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
- [Declarative layouts](https://macterm.thdxg.dev/docs/declarative-layouts), [Session persistence](https://macterm.thdxg.dev/docs/session-persistence), and [Remote projects](https://macterm.thdxg.dev/docs/remote-projects)
- [The `macterm` CLI](https://macterm.thdxg.dev/docs/cli)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, build, and PR guidelines.

## License

MIT
