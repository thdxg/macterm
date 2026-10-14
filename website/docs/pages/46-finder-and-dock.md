<!-- page:
slug: finder-and-dock
title: Finder and the Dock
nav: Finder and the Dock
group: Everyday use
description: Open a folder as a Macterm project from Finder, the Dock or the command line. Use the Dock menu of Macterm.
-->

# Finder and the Dock

Macterm opens folders from many places. Its Dock icon has its own menu.

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
