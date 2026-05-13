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

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, build, and PR guidelines.

## License

MIT
