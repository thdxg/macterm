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

The frames and the cross keep their silver and dark colors in every theme. The characters and the screen get colors of the theme. The grays are `palette = 15`, `7`, `8` and `0`:

| Part of the icon | Theme color |
| --- | --- |
| Characters | A blend of the theme's colors: `palette = 4` (blue) over all, with `palette = 1` (red) at the top left, `3` (yellow) at the top right, `5` (magenta) on the left, `2` (green) on the right and `6` (cyan) at the bottom left. |
| Screen | A color a small step away from `background`, as for a status bar or a popup: the nearest gray, mixed a little into `background`. That gray is usually `palette = 0`. |

The icon was drawn in eyesclosed, the default theme of Macterm. With eyesclosed, the Dock icon has the same colors as the usual icon of Macterm.

To turn it off, go to **Settings → Appearance → App Icon** and clear **Adaptive icon**.

The Dock icon does not change in these conditions:

- The icon style of macOS is Clear or Tinted (**System Settings → Appearance → Icon & widget style**). macOS then draws the icon in that style.
- You set `macos-icon = custom`. Your image is the Dock icon. See [Keys with no Settings equivalent](/docs/configuration#keys-with-no-settings-equivalent).
- Macterm is not running. Finder, Launchpad and the Dock then show the icon in its usual colors.
- The palette has no gray that is different from `background`. The Dock then shows the icon in its usual colors.

Macterm draws the icon with a part of macOS that Apple does not document. If a macOS update changes that part, Macterm shows the usual icon and continues to work.
