<!-- page:
slug: quick-terminal
title: Quick terminal
nav: Quick terminal
group: Everyday use
description: A global drop-down terminal with a hotkey. Its shells keep running when you quit.
-->

# Quick terminal

A drop-down terminal that is available from any app. Press <kbd>⌃`</kbd>. You can also select **View → Quick Terminal**, or **Toggle Quick Terminal** from the right-click menu of the Dock icon.

The keybind works when Macterm is not the active app. To change it, use **Toggle Quick Terminal** in **Settings → Keymaps**. To turn it off, clear the keybind there.

Its shells keep running in the same way as the shells of every other pane. If you quit while a build runs, the build keeps running. When you close a pane in the panel, its session ends.

## Position and size

Go to **Settings → Quick Terminal**. The position and the size each have a mode: **Fixed** or **Dynamic**.

| Mode | Position | Size |
| --- | --- | --- |
| **Fixed** (default) | Sliders for X and Y | Sliders for width and height |
| **Dynamic** | Drag the handle on the top edge of the panel. The panel opens again where you left it. | Drag the edges of the panel. The panel opens again at that size. |

## Quick terminal only

To run Macterm with no Dock icon and no menu bar, set `macos-hidden = always` in your Ghostty config. First read the trade-offs in [Configuration](/docs/configuration). You lose the keyboard route to Settings and Quit.
