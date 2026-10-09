<!-- page:
slug: session-persistence
title: Session persistence
nav: Session persistence
group: Projects & sessions
description: Terminal sessions keep running when you quit Macterm, because each pane uses a bundled zmx session.
-->

# Session persistence

The shell of each pane runs in a bundled `zmx` session. When you quit Macterm, it disconnects the panes and asks no confirmation. When you start Macterm again, it connects every pane to its session. Each pane keeps its scrollback and its running programs.

When you **close** a pane, a tab or a project, its shell ends. If a program is running, Macterm asks you first.

To list the live sessions, run this command in any pane:

```sh
zmx ls
```

> Local sessions do not keep running after you restart your Mac. The panes start again in their last working directory. Sessions in [remote projects](/docs/remote-projects) run on the host, so they keep running.

## Privacy prompts

A program that runs in a pane belongs to its session. It does not belong to the Macterm process. On macOS, the background process of the session is the *responsible process* of the program. The code signature of that process is the identity of Macterm itself. A Local Network request names **Macterm** when a program in a pane causes it. The same is true for a Files and Folders request and a Full Disk Access request. One grant covers every pane. The grant still applies after you quit and start Macterm again, and after an update.

> A session that an older version of Macterm started keeps its old attribution. Close its tab and open it again to change this.
