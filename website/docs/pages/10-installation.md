<!-- page:
slug: install
title: Installation
nav: Installation
group: Getting started
description: Install Macterm via Homebrew or a direct .dmg download.
-->

# Installation

## Homebrew

Recommended — the cask clears the Gatekeeper quarantine for you.

```sh
brew install --cask thdxg/tap/macterm
```

## From Releases

Download the latest `.dmg` from the [Releases page](https://github.com/thdxg/macterm/releases/latest), drag Macterm to Applications, then clear the quarantine flag once:

```sh
xattr -cr /Applications/Macterm.app
```

Sparkle handles updates from there, so you won't need `xattr` again.
