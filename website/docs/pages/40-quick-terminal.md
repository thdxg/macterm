<!-- page:
slug: quick-terminal
title: Quick terminal
nav: Quick terminal
group: Everyday use
description: A global drop-down terminal on a hotkey, whose shells survive a quit.
-->

# Quick terminal

A drop-down terminal available from any app. Press <kbd>⌃`</kbd>, or pick **View → Quick Terminal**, or **Toggle Quick Terminal** from the Dock icon's right-click menu.

Its shells persist like every other pane's: quit with a build running and it keeps running. Closing a pane in the panel is what ends its session.

## Position and size

**Settings → Quick Terminal**. Each has a **Fixed | Dynamic** mode.

| Mode | Position | Size |
| --- | --- | --- |
| **Fixed** (default) | Sliders for X and Y | Sliders for width and height |
| **Dynamic** | Drag the handle on the panel's top edge; it reopens where you left it | Drag the panel's edges; it reopens at that size |

## Quick terminal only

Set `macos-hidden = always` in your Ghostty config to run with no Dock icon and no menu bar. Read the trade-offs in [Configuration](/docs/configuration) first — you lose the keyboard route to Settings and Quit.
