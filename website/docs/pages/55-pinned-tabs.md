<!-- page:
slug: pinned-tabs
title: Pinned tabs
nav: Pinned tabs
group: Projects & sessions
description: Durable tabs above your projects. They start their commands again when their sessions end.
-->

# Pinned tabs

A pinned tab belongs to no project. It is above every project in the sidebar. It starts each time Macterm starts. If its sessions are gone, Macterm builds it again from its saved layout and runs its commands again. Pin the dev server, the log tail, or the ssh session that you always want.

## Pinning and unpinning

| Action | How |
| --- | --- |
| **Pin** | Drag a tab above every project and drop it. Or use the right-click menu of the tab, the command palette, or a keybind from Settings → Keymaps. |
| **Unpin** | Right-click the pinned row and select **Unpin Tab**. Or drag the row into a project section. |

Unpinning moves the tab. The tab goes back to the project that it came from, and its shells keep running. Pinning and unpinning never end a process.

When you pin a tab, Macterm saves its splits and the working directory of each pane. It also saves the program that runs in each pane, as the `run:` of that pane. When you start or stop a process, Macterm updates the saved layout within a few seconds.

## Closing unloads, never removes

When you press <kbd>⌘W</kbd> on a pinned tab, its processes end. The row stays, dimmed, with its saved layout. Select the row to start the tab again. The next time that Macterm starts, it starts the tab by itself. The same happens when its sessions end on their own. **Only unpinning removes a pinned tab.**

## pinned.yaml

The pinned tabs are in `~/.config/macterm/pinned.yaml`. Macterm keeps the file up to date, and you can edit it. (The file was in `~/.config/macterm/projects/`. The first time that Macterm runs, it moves an existing file up.)

```yaml
path: <pinned>
tabs:
  - name: dev server
    cwd: ~/dev/api
    run: npm run dev
  - cwd: ~/dev/api
```

| Edit | Effect |
| --- | --- |
| Add an entry | The entry becomes a pinned tab. It starts the next time that Macterm starts. |
| Remove an entry | The next time that Macterm starts, it unpins the tab. The tab goes back to the project that it came from. No process ends. |
| Change `run:`, `cwd:` or the splits | The change applies the next time that the tab starts again. |

Entries have no ids. Macterm matches an entry to a tab by `name:`, then by content, then by position. Give an entry a name before you make a large change, so Macterm can match it. Macterm reads the file again before each write, so it never overwrites your edits. If the file stops parsing, Macterm stops saving and shows an alert. It starts to save again when the file parses.

## Navigation

When a pinned tab is active, **Next/Previous Tab in Project** cycles through the pinned rows. The global **Next/Previous Tab** goes through the pinned tabs first. In the [CLI](/docs/cli), `--project pinned` selects the pinned tabs:

```sh
macterm tab list --project pinned
```

The name `pinned` always means the pinned tabs. No project can have the name Pinned. Macterm refuses the name where you type it. A folder with the name Pinned gets the project name `Pinned 2`.
