<!-- page:
slug: quick-terminal
title: Quick terminal
nav: Quick terminal
group: Everyday use
description: A global drop-down terminal on a hotkey, whose shells survive a quit.
-->

# Quick terminal

A global terminal accessible from anywhere with a hotkey — <kbd>⌃`</kbd> by default. It drops down over your current space, then gets out of your way when you're done. Its shells persist the way every other pane's do: quit Macterm with a build running in the quick terminal and it keeps running, the panel reopens onto it after a relaunch, and quitting asks no questions about it. Closing a pane in the panel is what ends its session. Its size and hotkey are configurable in **Macterm → Settings**. Besides the hotkey, **Quick Terminal** sits in the View menu and **Toggle Quick Terminal** in the menu you get by right-clicking Macterm's Dock icon — that one leaves whatever app you're in focused, just as the hotkey does.

Position and size each have a **Fixed | Dynamic** mode in **Settings → Quick Terminal**. Fixed — the default, centered — anchors the panel with sliders: X (left–right) and Y (top–bottom) for position, width and height for size. Dynamic hands the geometry to you instead: for position, a grab handle appears along the panel's top edge and dragging it moves the panel like a title bar would — it reopens where you left it, even tucked partly off a screen edge (if the screen changed underneath it, the panel nudges back only as far as it takes to stay grabbable). For size, the panel becomes resizable from its edges and reopens at the size you left it.

If the quick terminal is the only Macterm you want, set `macos-hidden = always` in your Ghostty config: Macterm then runs with no Dock icon, no menu bar and no <kbd>⌘</kbd><kbd>⇥</kbd> entry, and the panel keeps working exactly as it does now. Read the trade-offs first — an accessory app has no menu bar, so Settings and Quit lose their keyboard route. [Configuration](/docs/configuration) has the details.
