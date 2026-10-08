<!-- page:
slug: finder-and-dock
title: Finder and the Dock
nav: Finder and the Dock
group: Everyday use
description: Open a folder as a Macterm project from Finder, the Dock or the command line, and use Macterm's Dock menu.
-->

# Finder and the Dock

Macterm opens folders from wherever you find them, and its Dock icon has a menu of its own.

## Open a folder as a project

Any of these adds the folder as a new project and switches to it, launching Macterm first if needed:

- Right-click a folder in Finder → **Services → New Macterm Project Here**.
- Right-click a folder → **Open With → Macterm**.
- Drop a folder onto Macterm's Dock icon.
- Drop a folder onto Macterm's sidebar. Dropping it on a terminal pane still types its path, as before.
- Run `open -a Macterm ~/code/myproject`.

A file opened with **Open With**, dropped on the Dock icon, or passed to `open -a` goes to your terminal editor instead — see [Open files in your terminal editor](/docs/configuration#open-files-in-your-terminal-editor). If the Finder service is missing, enable it under System Settings → Keyboard → Keyboard Shortcuts → Services → Files and Folders.

## Dock menu

Right-click Macterm's Dock icon for **New Window**, **New Tab**, **New Project…** and **Toggle Quick Terminal**. New Tab and New Project… bring a terminal window forward first, including one you had closed.
