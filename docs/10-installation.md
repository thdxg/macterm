<!-- page:
slug: install
title: Installation
nav: Installation
group: Getting started
description: Install Macterm with Homebrew or a direct .dmg download.
-->

# Installation

## Homebrew

This is the recommended way. The cask clears the Gatekeeper quarantine for you.

```sh
brew tap macterm/tap
brew trust --cask macterm/tap/macterm
brew install --cask macterm/tap/macterm
```

Homebrew loads a cask from a tap that is not official only after you trust it. `brew trust` does this for the Macterm cask alone.

> The tap was `thdxg/tap` before November 2026. If you installed from it, `brew update` shows the commands that move Macterm to `macterm/tap`: the three lines above, with `brew reinstall --cask macterm` in place of the last one. Until you run them, Macterm keeps its updates through its own updater.

## From Releases

Download the latest `.dmg` from the [Releases page](https://github.com/macterm/macterm/releases/latest). Drag Macterm to Applications. Then clear the quarantine flag one time:

```sh
xattr -cr /Applications/Macterm.app
```

After that, Sparkle installs updates. You do not need `xattr` again.
