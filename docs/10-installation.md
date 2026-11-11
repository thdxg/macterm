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
brew install --cask macterm/tap/macterm
```

> The tap was `thdxg/tap` before November 2026. If you installed from it, `brew update` moves Macterm to `macterm/tap` for you.

## From Releases

Download the latest `.dmg` from the [Releases page](https://github.com/macterm/macterm/releases/latest). Drag Macterm to Applications. Then clear the quarantine flag one time:

```sh
xattr -cr /Applications/Macterm.app
```

After that, Sparkle installs updates. You do not need `xattr` again.
