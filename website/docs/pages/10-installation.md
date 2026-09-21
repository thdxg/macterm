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

Download the latest `.dmg`, drag Macterm to Applications, then clear the quarantine flag once:

```sh
xattr -cr /Applications/Macterm.app
```

Sparkle handles updates from there, so you won't need `xattr` again.

## Open a folder as a project

Any of these adds the folder as a new project and switches to it, launching Macterm first if needed:

- Right-click a folder in Finder → **Services → New Macterm Project Here**.
- Right-click a folder → **Open With → Macterm**.
- Drop a folder onto Macterm's Dock icon.
- Run `open -a Macterm ~/code/myproject`.

Files are ignored. If the Finder service is missing, enable it under System Settings → Keyboard → Keyboard Shortcuts → Services → Files and Folders.

## Dock menu

Right-click Macterm's Dock icon for **New Window**, **New Tab**, **New Project…** and **Toggle Quick Terminal**. New Tab and New Project… bring a terminal window forward first, including one you had closed.

## Update channels

Set **Update channel** in Settings → Updates.

| Channel | What you get |
| --- | --- |
| **Stable** | Tagged releases only. The default. |
| **Beta** | Stable releases plus betas. |
| **Tip** | Every commit on `main` that passes CI. Not release-tested — expect breakage. |

Narrowing the channel never downgrades what you already have; the next release above your version replaces it. Homebrew always tracks stable, so `brew upgrade` never installs a beta or tip build.
