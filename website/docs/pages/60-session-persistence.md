<!-- page:
slug: session-persistence
title: Session persistence
nav: Session persistence
group: Projects & sessions
description: Terminal sessions survive quitting Macterm via a bundled zmx session.
-->

# Session persistence

Terminal sessions survive quitting the app. Each pane's shell runs under a bundled `zmx` session, so quitting Macterm detaches — no confirmation dialog — without ending its processes. On relaunch, projects attach as they are opened and return with their scrollback and running processes intact.

To attach every restored project immediately, enable **Settings → General → Session Persistence → Attach all project terminals on launch**. Macterm connects each saved terminal in the background without changing your selection. This can open many local shells or SSH connections, so it is off by default. If a remote connection needs interactive authentication, open its tab to respond.

Closing a pane, tab, or project is what actually ends its shell (you'll be asked first if something is running). List live sessions from any pane:

```sh
zmx ls
```

> Local sessions don't survive a reboot (the daemon dies with the OS); panes respawn in their last working directory. Sessions in [remote projects](/docs/remote-projects) live on the host, so they *do* survive your Mac rebooting.
