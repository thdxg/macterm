<!-- page:
slug: session-persistence
title: Session persistence
nav: Session persistence
group: Projects & sessions
description: Terminal sessions survive quitting Macterm via a bundled zmx session.
-->

# Session persistence

Each pane's shell runs under a bundled `zmx` session. Quitting Macterm detaches — no confirmation — and relaunching reattaches every pane with its scrollback and running processes intact.

**Closing** a pane, tab, or project is what ends its shell. You're asked first if something is running.

List live sessions from any pane:

```sh
zmx ls
```

> Local sessions don't survive a reboot; panes respawn in their last working directory. Sessions in [remote projects](/docs/remote-projects) live on the host, so they do.
