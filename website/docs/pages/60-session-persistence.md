<!-- page:
slug: session-persistence
title: Session persistence
nav: Session persistence
group: Projects
description: Terminal sessions survive quitting Macterm via a bundled zmx session.
-->

# Session persistence

Terminal sessions survive quitting the app. Each pane's shell runs under a bundled `zmx` session, so quitting Macterm detaches — no confirmation dialog — and relaunching reattaches every pane with its scrollback and running processes intact.

Closing a pane, tab, or project is what actually ends its shell (you'll be asked first if something is running). List live sessions from any pane:

```sh
zmx ls
```

> Local sessions don't survive a reboot (the daemon dies with the OS); panes respawn in their last working directory. Sessions in [remote projects](/docs/remote-projects) live on the host, so they *do* survive your Mac rebooting.
