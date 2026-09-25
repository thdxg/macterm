<!-- page:
slug: pinned-tabs
title: Pinned tabs
nav: Pinned tabs
group: Projects & sessions
description: Durable tabs above your projects that restore their commands when their sessions die.
-->

# Pinned tabs

A pinned tab belongs to no project and sits above every project in the sidebar. It eager-loads on every launch, rebuilding from its saved layout and re-running its commands when the sessions didn't survive. Pin the dev server, the log tail, the ssh session you always want around.

## Pinning and unpinning

| Action | How |
| --- | --- |
| **Pin** | Drag a tab above every project and drop it, or use the tab's right-click menu, the command palette, or a keybind from Settings → Keymaps. |
| **Unpin** | Right-click the pinned row → **Unpin Tab**, or drag it into a project section. |

Unpinning is a move — the tab returns to its origin project with its shells still running. Nothing is killed by pinning or unpinning.

At pin time Macterm captures the tab's splits, each pane's working directory, and whatever is running as that pane's `run:`. Starting or stopping a process updates the capture within a couple of seconds.

## Closing unloads, never removes

<kbd>⌘W</kbd> on a pinned tab ends its processes but keeps the row (dimmed) and its saved layout. Select it to start it again; the next launch starts it automatically. The same happens when its sessions end on their own. **Unpinning is the only way a pinned tab goes away.**

## pinned.yaml

The pinned set lives in `~/.config/macterm/projects/pinned.yaml`, maintained automatically and still yours to edit.

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
| Add an entry | Appears as a pinned tab, spawning on the next launch. |
| Remove an entry | The tab is unpinned on the next launch — moved back to its origin project, never killed. |
| Change `run:`, `cwd:`, or splits | Applies the next time that tab restores. |

Entries carry no ids; Macterm matches them by `name:`, then content, then position. Name an entry to keep a heavy edit unambiguous. Macterm re-reads the file before every write, so your edits are never clobbered; if it stops parsing, auto-saving pauses with an alert until it parses again.

## Navigation

**Next/Previous Tab in Project** cycles the pinned rows while a pinned tab is active. Global **Next/Previous Tab** walks pinned tabs first. Over the [CLI](/docs/cli), `--project pinned` addresses the workspace:

```sh
macterm tab list --project pinned
```

Because `pinned` always means this workspace, no project can be named Pinned: the name is refused wherever you type it, and a folder called Pinned is added as `Pinned 2`.
