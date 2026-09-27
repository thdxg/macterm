<!-- page:
slug: desktop-widgets
title: Desktop widgets
nav: Desktop widgets
group: Everyday use
description: Terminals that live on the desktop, sized and shaped like the system's widgets, whose shells survive a quit.
-->

# Desktop widgets

A desktop widget is a terminal on your desktop. It sits with the system's own widgets, below every window, and stays put through Mission Control and Show Desktop. It appears on every Space.

Add one with **File → New Desktop Widget**, **New Desktop Widget** in the command palette, or the **+** in **Settings → Widgets**. It opens in the middle of the desktop, running your login shell.

Its shell persists like a pinned tab's. Quit Macterm with something running in a widget and it keeps running. On the next launch the widget comes back in the same place, attached to the same shell.

## Locked and editing

Widgets are **locked**. A locked widget behaves like a system widget: drag it anywhere to move it, but nothing you click, type or scroll reaches its terminal, text selection included. It just shows what its terminal is doing.

To use one, right-click it and choose **Edit Widget**. While you edit it:

- it has an accent-colored outline and a **Done** button, so you can always tell which widget is live;
- its terminal takes keyboard and mouse input like any other pane, so a drag inside it selects text;
- drag it by its border (the margin around the terminal) to move it;
- drag an edge or corner to resize it.

Click **Done**, or right-click the border → **Done Editing**, to lock it again. Only one widget can be edited at a time: **Edit Widget** stays greyed out on the others until you're done.

Typing into a widget leaves the app you were in at the front.

## The grid

Widgets snap to a grid when you let go of a move or a resize. The grid is the system widgets' own: 164-point cells with 16-point gaps, laid out from the top-left of each screen. A widget can span any number of cells. The right-click menu offers the system's four sizes: **Small** (1×1), **Medium** (2×1), **Large** (2×2) and **Extra Large** (4×2). Widgets never overlap: one dropped onto another moves to the nearest free cell.

## Settings → Widgets

**Default size** sets the size of new widgets. The **Widgets** list shows every widget, including ones hidden behind windows or on another display, with **Edit**/**Done**, a size menu and **Remove** for each. **+** adds a widget.

Removing a widget ends its shell. If a program is still running in it, Macterm asks first.

If a widget's shell exits (`exit`, or its session is killed), the widget starts over with a fresh shell instead of disappearing.

## widgets.yaml

The widgets live in `~/.config/macterm/widgets/widgets.yaml`. Macterm maintains the file automatically, and it's still yours to edit.

```yaml
widgets:
  - name: logs              # optional; shown in Settings
    size: medium            # small, medium, large, extra-large, or a span like 3x2
    column: 3               # the grid cell of the top-left corner,
    row: 1                  #   counted from the top-left of the screen
    display: DELL U2723QE   # optional; the screen by name, else the primary display
    cwd: ~/dev/api          # where a fresh shell starts
    run: tail -f log/dev.log
```

`cwd` and `run` are the widget's recipe for starting fresh: when it's created, when its shell exits, and after a reboot, when there's no session left to reattach. Macterm records them from what the widget is actually running, the same way a [pinned tab](/docs/pinned-tabs) records its commands.

| Edit | Effect |
| --- | --- |
| Add an entry | Becomes a widget running its `run:`. |
| Remove an entry | Its widget is removed on the next launch. |
| Change `size`, `column`, `row` or `display` | The widget moves and resizes on the next launch, or the next time Macterm writes the file. |
| Change `run:` or `cwd:` | Applies the next time the widget starts fresh. |

Entries carry no ids. Macterm matches them to widgets by `name:`, then by content, then by position, so name an entry before editing it heavily. Macterm re-reads the file before every write, so your edits are never clobbered. If the file stops parsing, auto-saving pauses with an alert until it parses again.

## From the CLI

```sh
macterm widget new --size large --name top --run htop
macterm widget list
macterm widget edit widget:1
macterm widget done
macterm widget set widget:1 --size 3x2
macterm widget remove widget:1
```

A widget's pane has no project or tab. Address it by the session name `widget list` shows. The CLI can type into a locked widget; the lock only covers the mouse and keyboard.

```sh
macterm pane dump --session macterm-widget-3f9a2c1d4b7e
```

## Why not a real macOS widget

macOS widgets (WidgetKit) are static snapshots that the system redraws a few times an hour. They can't show a live terminal or accept typing. They also only load from apps signed with an Apple Developer team, which Macterm isn't. So Macterm draws the widget itself, and it doesn't appear in the desktop's **Edit Widgets** gallery.
