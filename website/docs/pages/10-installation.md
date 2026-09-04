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

## Update channels

Set **Update channel** in Settings → Updates. The channel governs what any check can see, so it applies equally to the daily background check and to **Check for Updates…**.

| Channel | What you get |
| --- | --- |
| **Stable** | Tagged releases only. The default. |
| **Beta** | Stable releases plus betas, which ship ahead of a stable release and may be unstable. |
| **Tip** | Every commit on `main` that passes CI, built within about half an hour of merging. Not release-tested — expect breakage. |

Switching to a narrower channel stops future updates from the wider one but never downgrades what you already have; the next release above your version replaces it. Because a tip build is newer than the stable release it was cut from, moving from **Tip** back to **Stable** means waiting for the next stable release.

Tip builds are also downloadable directly from the [`tip` release](https://github.com/thdxg/macterm/releases/tag/tip), which always points at the newest one. A tip `.dmg` follows the tip channel by default, so installing one by hand still keeps you updated.

Homebrew always tracks stable releases. `brew upgrade` never installs a beta or a tip build, so opting in only affects Macterm's own updater.
