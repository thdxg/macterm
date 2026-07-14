<!-- page:
slug: install
title: Installation
nav: Installation
group: Getting started
description: Install Macterm via Homebrew or a direct .dmg download.
-->

# Installation

## Homebrew

The recommended way to install. The cask strips the Gatekeeper quarantine attribute on install, so the app launches without extra prompts.

```sh
brew install --cask thdxg/tap/macterm
```

## From Releases

Download the latest `.dmg`, open it, and drag Macterm to Applications. Since the app isn't signed with an Apple Developer certificate, clear the quarantine flag once:

```sh
xattr -cr /Applications/Macterm.app
```

Sparkle handles updates from there — Macterm checks daily in the background and verifies an EdDSA signature on each update, so you won't need `xattr` again.
