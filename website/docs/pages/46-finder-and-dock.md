<!-- page:
slug: finder-and-dock
title: Finder and the Dock
nav: Finder and the Dock
group: Everyday use
description: Open a folder as a Macterm project from Finder, the Dock or the command line. Use the Dock menu of Macterm, and the Dock icon that takes the colors of your theme.
-->

# Finder and the Dock

Macterm opens folders from many places. Its Dock icon has its own menu, and it takes the colors of your terminal theme.

## Open a folder as a project

Each of these actions adds the folder as a new project and selects the project. If Macterm is not running, the action starts it first:

- In Finder, right-click a folder and select **Services → New Macterm Project Here**.
- Right-click a folder and select **Open With → Macterm**.
- Drop a folder on the Macterm Dock icon.
- Drop a folder on the Macterm sidebar. If you drop a folder on a terminal pane, Macterm types its path, as before.
- Run `open -a Macterm ~/code/myproject`.

A file that you open with **Open With**, drop on the Dock icon, or pass to `open -a` goes to your terminal editor. See [Open files in your terminal editor](/docs/configuration#open-files-in-your-terminal-editor). If the Finder service is missing, turn it on in System Settings → Keyboard → Keyboard Shortcuts → Services → Files and Folders.

## Dock menu

Right-click the Macterm Dock icon to see **New Window**, **New Tab**, **New Project…** and **Toggle Quick Terminal**. **New Tab** and **New Project…** first bring a terminal window forward. This includes a window that you closed.

## Adaptive icon

On macOS 26 and later, the Dock icon shows the colors of your terminal theme. The icon keeps its Liquid Glass. The app switcher (<kbd>⌘</kbd><kbd>⇥</kbd>) shows the same icon. When you change the theme and reload the config, or when macOS changes between light and dark, the icon changes too.

Each pane of the icon is one color from the palette of the theme. The panes go from the front pane down toward the background in even steps of lightness:

| Part of the icon | Theme color |
| --- | --- |
| Frame and front pane | The gray that stands out most from the background: `palette = 15`, `7`, `8` or `0` |
| Back pane | Another of those grays, at about half that distance from the background. This is usually `palette = 8`. |
| Middle pane | The color from `palette = 1` to `6` and `9` to `14` whose lightness is nearest the middle between the back pane and the front pane |
| Background | `background`, with `palette = 0` mixed in at the top |

The icon was drawn in eyesclosed, the default theme of Macterm. With eyesclosed, the Dock icon has the same colors as the usual icon of Macterm.

To turn it off, go to **Settings → Appearance → App Icon** and clear **Adaptive icon**.

The Dock icon does not change in these conditions:

- The icon style of macOS is Clear or Tinted (**System Settings → Appearance → Icon & widget style**). macOS then draws the icon in that style.
- You set `macos-icon = custom`. Your image is the Dock icon. See [Keys with no Settings equivalent](/docs/configuration#keys-with-no-settings-equivalent).
- Macterm is not running. Finder, Launchpad and the Dock then show the icon in its usual colors.

Macterm draws the icon with a part of macOS that Apple does not document. If a macOS update changes that part, Macterm shows the usual icon and continues to work.
