<h1 align="center">
  <img src="./assets/icon.png" width="128" />
  <br />
  ▞▚ macterm ▞▚
</h1>

<p align="center">
  macterm is a modern terminal multiplexer for macOS, featuring a native sidebar for vertical project and tab management. Built with SwiftUI and powered by libghostty.
</p>

![screenshot](./assets/screenshot.png)

## Features

- **Vertical Project Sidebar**: Native macOS sidebar for organizing projects and tabs vertically.
- **Split Panes**: Unlimited horizontal and vertical splits.
- **Persistence**: Workspaces are saved and restored automatically.
- **Quick Terminal**: Global dropdown terminal accessible from anywhere.
- **Highly Configurable**: Custom hotkeys, themes, and more.

## Install

Download the latest `.dmg` from [Releases](https://github.com/thdxg/macterm/releases), open it, and drag Macterm to Applications.

Since the app is not signed with an Apple Developer certificate, macOS will block it on first launch. To fix this, run:

```bash
xattr -cr /Applications/Macterm.app
```

## Requirements

- macOS 26.0+
- Swift 6.0+
- [mise](https://mise.jdx.dev/) (optional, but recommended)

## Quick Start

```bash
# Install necessary tools (swiftlint, gh, etc.)
mise install

# Setup dependencies
mise run setup

# Run in debug mode
mise run run

# Build release bundle
mise run build
```

## License

MIT
