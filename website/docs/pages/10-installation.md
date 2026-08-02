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

## Beta updates

Betas ship ahead of stable releases and may be unstable. To receive them, set **Update channel** to **Beta** in Settings → Updates. Macterm then offers beta builds on both the daily background check and **Check for Updates…**; on **Stable** you only ever see stable releases.

Switching back to Stable stops future beta updates but doesn't downgrade a beta you already have — the next stable release above your version replaces it.

Homebrew always tracks stable releases. `brew upgrade` never installs a beta, so opting in only affects Macterm's own updater.
