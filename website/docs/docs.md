<!-- section: intro | Introduction | Overview -->

<p class="eyebrow">Documentation</p>

# Macterm

A native macOS terminal with a vertical project sidebar and persistent multiplexing, built on [libghostty](https://ghostty.org). Quit anytime — your projects, tabs, and split panes come back exactly as you left them.

Macterm requires macOS 14 or later and is MIT licensed.

<!-- section: install | Install | Getting started -->

## Install

### Homebrew

The recommended way to install. The cask strips the Gatekeeper quarantine attribute on install, so the app launches without extra prompts.

```sh
brew install --cask thdxg/tap/macterm
```

### From Releases

Download the latest `.dmg`, open it, and drag Macterm to Applications. Since the app isn't signed with an Apple Developer certificate, clear the quarantine flag once:

```sh
xattr -cr /Applications/Macterm.app
```

Sparkle handles updates from there — Macterm checks daily in the background and verifies an EdDSA signature on each update, so you won't need `xattr` again.

<!-- section: configuration | Configuration | Getting started -->

## Configuration

Macterm reads your `~/.config/ghostty/config` on launch — themes, fonts, palettes, keybinds, and everything else Ghostty supports work the same here. If your config lives elsewhere, set the path in **Settings → General → Ghostty Config**.

Macterm-specific settings — window opacity, blur style, quick-terminal size, and hotkeys — live in **Macterm → Settings**. A few Ghostty keys are overridden because Macterm owns that chrome: `background-opacity` and `background-blur` are forced to `0` (use Settings instead), and titlebar, window-decoration, split-divider, and quick-terminal settings are ignored.

> The `ssh-env`, `ssh-terminfo`, and `path` features require the `ghostty` CLI — install Ghostty.app to enable them.

<!-- section: command-palette | Command palette | Usage -->

## Command palette

Press <kbd>⌘P</kbd> to open the command palette — the fastest way to drive Macterm without leaving the keyboard. It searches everything in one list:

- **Commands** — split, close, and focus panes; create, rename, and reorder tabs; toggle window chrome. Each row shows its current keybind.
- **Projects** — jump to any open project, or rename and remove them.

To open a directory as a project, start typing a path (anything beginning with `/` or `~`). The palette switches to path mode and autocompletes directories as you go.

<!-- section: quick-terminal | Quick terminal | Usage -->

## Quick terminal

A global terminal accessible from anywhere with a hotkey — <kbd>⌃`</kbd> by default. It drops down over your current space, then gets out of your way when you're done. The quick terminal is scratch space: its sessions end on every quit, and its size and hotkey are configurable in **Macterm → Settings**.

<!-- section: layouts | Declarative layouts | Projects -->

## Declarative layouts

Describe a project's tabs, split layout, and the process each pane runs in a YAML file, and Macterm builds the workspace from it. Project files live in `~/.config/macterm/projects/`, one per project — they're matched to a project by their `path`, not their filename, so the filename is just cosmetic.

```yaml title="~/.config/macterm/projects/myapp.yaml"
name: "MyApp"
path: "~/dev/myapp"
tabs:
  - run: "npm run dev"
  - name: "Dev"
    split:
      direction: horizontal
      ratio: 0.6
      first:  { cwd: "./api", run: "npm run dev" }
      second: {} # plain shell pane
```

Each tab is a layout node: a leaf pane (`cwd` / `run` / `shell`) or a `split` with a `direction`, a `ratio`, and `first` / `second` children. A bare `{}` is a plain shell.

Run **Save layout** from the palette to write your current workspace out, or **Apply layout** to reconcile the live workspace toward the file — matching panes are kept, only ones that drifted are restarted.

> The older in-project `.macterm/layout.yaml` still seeds a project on first open, but it's deprecated in favor of the central files above.

<!-- section: persistence | Session persistence | Projects -->

## Session persistence

Terminal sessions survive quitting the app. Each pane's shell runs under a bundled `zmx` session, so quitting Macterm detaches — no confirmation dialog — and relaunching reattaches every pane with its scrollback and running processes intact.

Closing a pane, tab, or project is what actually ends its shell (you'll be asked first if something is running). List live sessions from any pane:

```sh
zmx ls
```

> Sessions don't survive a reboot (the daemon dies with the OS); panes respawn in their last working directory.
