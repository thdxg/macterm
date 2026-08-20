<!-- page:
slug: pinned-tabs
title: Pinned tabs
nav: Pinned tabs
group: Projects & sessions
description: Durable tabs above your projects that restore their commands when their sessions die.
-->

# Pinned tabs

A pinned tab belongs to no project. It sits above every project in the sidebar as a top-level row with a pin icon, and it is the most durable thing in the app: it can't be closed, it survives restarts like any tab, and if its underlying session ever dies — a reboot, an `exit`, a crashed process — selecting it rebuilds the tab from its saved layout, **re-running the commands it was pinned with**. Pin the dev server, the log tail, the ssh session you always want around.

## Pinning and unpinning

- **Pin** — drag a tab to the very top of the sidebar: a **Pin Tab** band appears; drop to pin. (Dropping onto an existing pinned row pins at that slot instead.) Also in the tab's right-click menu and the command palette, and bindable in Settings → Keymaps.
- **Unpin** — right-click a pinned row → **Unpin Tab**, or drag it into a project section. Unpinning is a *move*: the tab returns to the project it came from (its shells keep running). Nothing is killed by pinning or unpinning.

At pin time Macterm captures the tab's layout the same way **Save Layout** does — splits, each pane's working directory, and whatever command is running becomes the pane's `run:`. The capture then tracks the tab: starting or stopping a process in a pinned pane updates the saved layout (and `pinned.yaml`) within a couple of seconds, and it refreshes once more on quit — so a restore re-runs the last thing the tab was doing.

## Pinned tabs can't be closed

<kbd>⌘W</kbd> and Close Tab refuse on a pinned tab (`macterm tab close` returns a `pinned` error, `--force` included). The only ways a pinned tab goes away are unpinning it, or its own sessions ending — typing `exit`, a crash, a reboot. When that happens the row stays, dimmed: select it and the tab respawns from its saved layout, commands and all.

## `pinned.yaml`

The pinned set lives in `~/.config/macterm/projects/pinned.yaml` — the one layout file Macterm maintains automatically (on pin, unpin, and quit). It's still yours to edit:

```yaml
pinned: true
tabs:
  - name: dev server
    cwd: ~/dev/api
    run: npm run dev
  - cwd: ~/dev/api
```

- **Add an entry** (no `id:` needed — Macterm assigns one) and it appears as a pinned tab, spawning when selected.
- **Remove an entry** and the tab is unpinned on the next launch (moved back to its origin project — never killed).
- **Edit an entry** (`run:`, `cwd:`, splits) and the change applies the next time that tab restores.

Your edits are never clobbered: Macterm re-reads the file before every write and folds external changes in first. If the file doesn't parse mid-edit, auto-saving pauses (with an alert) until it parses again. Because it lives with your other layout files, `pinned.yaml` dotfile-syncs — the pinned *set* follows you across machines, while the live sessions stay per-machine.

Over the [control CLI](/docs/cli), `--project pinned` addresses the pinned workspace (`macterm tab list --project pinned`).
