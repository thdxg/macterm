<h1 align="center">
  <img src="./assets/icon.png" width="128" />
  <br />
  Macterm
</h1>

<p align="center">
  A lightweight, native terminal for macOS built with SwiftUI and libghostty.
</p>

![screenshot](./assets/screenshot.png)

## Features

- **Vertical Project Sidebar**: Native macOS sidebar for organizing projects and tabs vertically.
- **Split Panes**: Unlimited horizontal and vertical splits, with optional auto-tiling.
- **Persistence**: Projects, tabs, and panes are saved and restored automatically.
- **Quick terminal**: Global terminal accessible from anywhere.
- **Highly Configurable**: Configurable theme, font, and keymap with hot-reloading.
- **Command Palette**: Versatile command palette to interact with multiplexing (open, delete, and search projects)

## Install

Download the latest `.dmg` from [Releases](https://github.com/thdxg/macterm/releases), open it, and drag Macterm to Applications.

Since the app isn't signed with an Apple Developer certificate, macOS will block it on first launch with a "_Macterm.app Not Opened_" dialog. Dismiss the dialog, then:

1. Open **System Settings → Privacy & Security**.
2. Scroll to the **Security** section — you'll see _"Macterm.app was blocked…"_ with an **Open Anyway** button. Click it.
3. Launch Macterm again and confirm.

You only need to do this once. (Or, from Terminal: `xattr -cr /Applications/Macterm.app`, then launch normally.)

## Development

### Requirements

- macOS 26.0+
- Swift 6.0+
- [mise](https://mise.jdx.dev/) (optional, but recommended)

### Quick Start

```bash
# Install necessary tools (swiftlint, gh, etc.)
mise install

# Setup dependencies
mise run setup

# Run in debug mode
mise run run

# Build release bundle
mise run build

# Run the test suite
mise run test
```

## License

MIT
