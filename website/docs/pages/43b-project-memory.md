<!-- page:
slug: project-memory
title: Project Memory
nav: Project Memory
group: Everyday use
description: See where you left off in a project, its Git state, and the commands to run next, in a panel next to your terminal.
-->

# Project Memory

Project memory records the commands that finish in each project. A panel next to your terminal then shows where you left off, the state of the project's Git repository, and the commands that you will probably run next. Click a command to run it in a new split.

Macterm stores the records on your Mac only. It does not record the output of your terminal: it keeps only the command, its folder, its exit code and its time, plus the last lines of output of a command that fails.

## Requirements

- macOS 26 or later.

Project memory does not use Apple Intelligence. It works on every Mac with macOS 26.

## Turn on project memory

Project memory is off until you turn it on.

1. Open **Settings → Intelligence**.
2. Turn on **Record commands for project memory**.

You can also open the panel and click **Turn On Project Memory**.

## Open the panel

Press <kbd>⌥</kbd><kbd>⌘</kbd><kbd>0</kbd>, or click the panel button in the toolbar. You can also run **Toggle Project Memory** from the command palette or from the **View** menu. Each window has its own panel, and the panel shows the project of its window.

The panel floats over the right side of the terminal. It does not make your panes smaller. To hide it, press <kbd>⌥</kbd><kbd>⌘</kbd><kbd>0</kbd> again or click the panel button in the toolbar. The project icon in the panel is the icon that you chose in **Settings → Appearance → Project icon**, with the color of the project.

The panel has these sections:

| Section | What it shows |
| --- | --- |
| **Where You Left Off** | When the last command finished. If the latest run of a command failed and you did not run it again with success, the panel shows that command, its exit code and the last lines of its output. |
| **Next** | Up to six commands to run: the failed command again, Git actions, and the commands that you run most often in this project. Recent runs count more. |
| **Git** | The branch, the commits ahead of and behind the upstream, the changed files, the stashes and the five latest commits. |
| **Recent** | The latest commands. Click one to run it again. |

A command that you click runs in a new split next to the focused pane. Macterm types it into your shell, so it runs in the same shell language as before and goes into your shell history.

## What Macterm records

Macterm records a command when the shell reports that it finished (OSC 133). This needs [shell integration](/docs/configuration). Macterm reads the command from the prompt line when you press Return, up to the cursor, so a command that clears the screen, such as `clear`, is recorded too, and a right prompt or an autosuggestion after the cursor is not part of it. In bash and zsh, the shell integration sends no mark for the first prompt of a pane, so the first command of a new pane is read only when it finishes. The output tail of a failed command comes from the screen after the next prompt shows. If Macterm cannot read the command, it records nothing. A tab that two windows show records each command one time.

Macterm does not record:

- A command that starts with a space. This is the `HISTCONTROL=ignorespace` convention of shells.
- The commands of the pinned tabs, the scratch tabs, the quick terminal and desktop widgets. These do not belong to a project.

Before Macterm stores a command or its output, it replaces secrets with `•••`. The panel does not run such a command again, because it would type the mask in place of the secret. These are values of names such as `TOKEN`, `SECRET`, `PASSWORD` and `API_KEY`, `Authorization` headers, `--password` options, passwords in URLs and keys with a known shape (GitHub, Slack, AWS). This filter cannot find every secret. To keep a command out of the records, start it with a space.

Each project keeps its 500 latest commands, in `~/Library/Application Support/Macterm/Memory/`.

## Git

Macterm reads the Git state of a local project when the panel shows it, after a command finishes while a panel shows the project, when Macterm becomes the active app, and every 15 seconds while the panel shows and Macterm is active. Macterm does not fetch from the remote, so the number of commits behind the upstream changes only after a fetch, for example when you click **Pull**. Macterm uses the Git of Homebrew, or the Git of the Xcode Command Line Tools. If neither is installed, the panel shows no Git state. Macterm never opens the install dialog of the Command Line Tools.

The panel does not show the Git state of a remote project yet.

## Forget the records

To forget all projects, open **Settings → Intelligence**, then click **Forget All…**. When you remove a project, Macterm deletes its records too.
