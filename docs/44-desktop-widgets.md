<!-- page:
slug: desktop-widgets
title: Desktop widgets
nav: Desktop widgets
group: Everyday use
description: Terminals on the desktop. They use the grid of the system widgets and have the same shape. Their shells keep running when you quit.
-->

# Desktop widgets

A desktop widget is a terminal on your desktop. It is with the system widgets, below every window. It stays in place in Mission Control and Show Desktop. It appears on every Space.

To add a widget, use **File → New Desktop Widget**, **New Desktop Widget** in the command palette, or the **+** in **Settings → Widgets**. The widget opens in the middle of the desktop. It is 3×3 grid cells and runs your login shell.

Its shell keeps running in the same way as the shell of a pinned tab. If you quit Macterm while a program runs in a widget, the program keeps running. The next time that Macterm starts, the widget comes back in the same place, connected to the same shell.

## Locked and editing

Widgets are **locked**. A locked widget behaves like a system widget. You can drag it to move it. Nothing that you click, type or scroll reaches its terminal. This includes text selection. The widget only shows what its terminal does.

To use a widget, right-click it and select **Edit Widget**. While you edit a widget:

- It has an outline in the accent color and a **Done** button. You can always see which widget is live.
- Its terminal takes keyboard and mouse input like any other pane. A drag inside it selects text.
- Drag its border (the margin around the terminal) to move it.
- Drag an edge or a corner to change its size.

To lock the widget again, click **Done**. You can also right-click the border and select **Done Editing**. You can edit only one widget at a time. **Edit Widget** is gray on the other widgets until you finish.

When you type into a widget, the app that you were in stays in front.

## The grid

When you release a widget after a move or a resize, it snaps to a grid. The grid is the grid of the system widgets: 164-point cells with 16-point gaps. A widget can span any number of cells. To change the size of a widget, edit it and drag an edge or a corner. A new widget opens in the exact middle of the screen. It joins the grid the first time that you move it or change its size. If the middle is not free, the widget opens in the nearest free cell.

Macterm lines up widgets in groups, as macOS does. If you release a widget next to another widget, it snaps into line with that widget. This includes a system widget. If you release a widget in open space, it snaps to the grid of the screen. That grid starts where macOS puts widgets against the top-left corner. Widgets never overlap. They never cover the system widgets. A widget that you drop on another widget moves to the nearest free cell.

## Changing displays

Widgets follow your displays in the same way as the system widgets. Each widget remembers where you put it on each display, at each resolution. When you unplug an external display, its widgets move to the display that stays. They keep the same distance from the top-left corner. If a widget would land off the screen, Macterm pulls it back onto the screen. When you plug the display in again, the widgets return to the exact places where you left them.

If you move a widget on the smaller display, it also gets a place there. It keeps its place on the other display. A display change can move a widget onto the screen. That move is not permanent. Macterm saves nothing until you move the widget yourself.

## Settings → Widgets

The **Widgets** list shows every widget, with its size and a **Remove** button. This includes widgets that are behind windows or on another display. The icon of the widget that you edit has the accent color. **+** adds a widget.

When you remove a widget, its shell ends. If a program is still running in the widget, Macterm asks you first.

If the shell of a widget exits (`exit`, or someone kills its session), the widget starts again with a new shell. It does not disappear.

## widgets.yaml

The widgets are in `~/.config/macterm/widgets.yaml`, next to `pinned.yaml`. Macterm keeps the file up to date, and you can edit it.

```yaml
widgets:
  - name: logs              # optional; shown in Settings
    size: 3x2               # the grid span, COLUMNSxROWS
    column: 3               # the grid cell of the top-left corner,
    row: 1                  #   counted from the top-left of the screen
    display: DELL U2723QE   # the screen by name; Macterm always writes it
    cwd: ~/dev/api          # where a fresh shell starts
    run: tail -f log/dev.log
```

`cwd` and `run` are the recipe of the widget for a fresh start. The widget uses them in three cases: when you create it, when its shell exits, and after a restart of your Mac. After a restart, no session is left to connect to. Macterm records them from what the widget really runs. A [pinned tab](/docs/pinned-tabs) records its commands in the same way.

| Edit | Effect |
| --- | --- |
| Add an entry | The entry becomes a widget that runs its `run:`. |
| Remove an entry | Macterm removes the widget the next time that it starts. |
| Change `size`, `column`, `row` or `display` | The widget moves and changes size the next time that Macterm starts, or the next time that Macterm writes the file. If a display is not connected, the cell stays for the time when it is. |
| Change `run:` or `cwd:` | The change applies the next time that the widget starts fresh. |

Entries have no ids. Macterm matches an entry to a widget by `name:`, then by content, then by position. Give an entry a name before you make a large edit. Macterm reads the file again before each write, so it never overwrites your edits. If the file stops parsing, Macterm stops saving and shows an alert. It starts to save again when the file parses.

## From the CLI

```sh
macterm widget new --size 4x3 --name top --run htop
macterm widget list
macterm widget edit widget:1
macterm widget done
macterm widget set widget:1 --size 3x2
macterm widget remove widget:1
```

A widget pane has no project and no tab. Address it with the session name that `widget list` shows. The CLI can type into a locked widget. The lock covers only the mouse and the keyboard.

```sh
macterm pane dump --session macterm-widget-3f9a2c1d4b7e
```

## Why not a real macOS widget

macOS widgets (WidgetKit) are static snapshots. The system draws them again a few times each hour. They cannot show a live terminal and they cannot accept typing. They also load only from apps that an Apple Developer team signed, and Macterm is not one of them. So Macterm draws the widget itself. The widget does not appear in the **Edit Widgets** gallery of the desktop.
