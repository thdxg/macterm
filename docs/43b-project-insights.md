<!-- page:
slug: project-insights
title: Project Insights
nav: Project Insights
group: Everyday use
description: See where you left off in a project, its Git state, and the commands to run next, in a panel next to your terminal.
-->

# Project Insights

Project Insights records the commands that finish in each project. A panel next to your terminal then shows where you left off, the state of the project's Git repository, and the commands that you will probably run next. Click a command to run it in a new split.

Macterm stores the records on your Mac only. It does not record the output of your terminal: it keeps only the command, its folder, its exit code and its time, plus the last lines of output of a command that fails.

## Requirements

- macOS 26 or later.
- A Mac that can run Apple Intelligence, with Apple Intelligence turned on in **System Settings**.

Without Apple Intelligence, the **Enable Project Insights** switch is dimmed, and its description ends with the reason. Macterm records nothing, and the command, the button and the panel are not there. When you turn on Apple Intelligence again, Project Insights comes back as you set it.

## Turn on Project Insights

Project Insights is off until you turn it on.

1. Open **Settings → Intelligence**.
2. Turn on the **Enable Project Insights** switch.

When it is on, Macterm records the commands that finish in all your projects. The command **Toggle Project Insights** and the panel button in the toolbar are available. When it is off, Macterm records nothing. The command, the button and the panel are not there.

## Open the panel

Press <kbd>⌘</kbd><kbd>I</kbd>, or click the panel button in the toolbar. You can also run **Toggle Project Insights** from the command palette or from the **View** menu. The panel is one setting for all windows: when it is on, every window shows the panel of its own project.

The panel floats over the right side of the terminal. It does not make your panes smaller. To hide it, press <kbd>⌘</kbd><kbd>I</kbd> again or click the panel button in the toolbar. The project icon in the panel is the icon that you chose in **Settings → Appearance → Project icon**, with the color of the project.

To remove the panel button from the toolbar, turn off **Settings → Appearance → Toolbar → Show Project Insights button**, or right-click the toolbar and clear **Project Insights Button**. <kbd>⌘</kbd><kbd>I</kbd> and the **View** menu still show and hide the panel.

The panel has these sections:

| Section | What it shows |
| --- | --- |
| **Summary** | A short paragraph that says where you left off (see [Summary](#summary)). If a command failed and you did not fix it, the panel shows that command, its exit code and the last lines of its output. A later success of the same command, also with other options (`git clean -f` after `git clean`), fixes it. A failure before a pause of an hour or more with no command is not shown. |
| **Suggested** | Up to five commands to run next. The model chooses them from the commands that ran in this project and a few Git commands, with a reason for each. It never makes up a command: a suggestion that is not a command of this project, or `git status`, `git pull`, `git fetch`, `git diff`, `git log` or `git stash list`, is dropped. It suggests a command only for a cause that it sees, such as a failed run or the Git state, never because the command ran recently. When it has nothing to suggest, the panel shows no Suggested section. |
| **Git** | The branches with the latest commits, the current one highlighted. Click a branch to go to it in the current pane: Macterm types `cd` to the worktree that has the branch checked out, or `git switch` for a branch with no worktree. The pane must be at a prompt. |
| **Recent** | The latest commands. Click one to run it again. |

A command that you click runs in a new split next to the focused pane. Macterm types it into your shell, so it runs in the same shell language as before and goes into your shell history.

## Summary

A paragraph at the top of the **Summary** section says what you were working on. Apple's on-device model writes it from the Git state first (the commits of the current branch, or the latest commits on a main branch, the changed files and, when you have uncommitted changes, what changed in them). The model reads the recorded commands only when Git shows no commits and no changed files, because the **Recent** list already shows them. Nothing leaves your Mac.

When a tracked file has uncommitted changes, the model also reads the diff of the staged and unstaged changes, so that the summary can say what you changed and not only which files. Macterm leaves out binary files, lockfiles, `.env` files, key files, files and folders with "secret" or "credential" in the name, files with a private key, and files with very long lines, such as minified code. The diff goes only to the on-device model, and Macterm does not keep it. The model is told not to write a secret, and Macterm replaces secrets in the summary with `•••`, with the same filter as for the output of a command (see [What Macterm records](#what-macterm-records)). This filter cannot find every secret. A long diff is cut a whole file at a time. Macterm does not read the diff of a commit or of a file that Git does not track.

Macterm writes the summary ten minutes after the last command in a project, panel or no panel, so that a panel you open after a break shows it at once. It does not write it while you work: a command that finishes only starts the ten minutes again. A change in the Git state that the summary has not seen, such as a commit from another terminal, starts the ten minutes too. A project with no summary yet gets one as soon as Macterm reads its Git state, with no wait: the branch in use, its commits and its changes. Macterm keeps the summary with the records, so it is there after you start Macterm again. To write it now, click the reload button in the header of the **Summary** section. While the model writes, the panel shows **Summarizing…** until the first words arrive, and the facts below it do not wait.

## Ask Siri or Shortcuts

The action **Where Did I Leave Off** returns the same answer as text, for a project that you select. Say "Where did I leave off in Macterm" to Siri, or add the action to a shortcut. The text is the summary when Macterm wrote one, then the commands that finished after it. Without a summary, it is the latest command and its result, and a failed command that the panel shows. The action never writes a summary. See [Shortcuts](/docs/shortcuts).

## What Macterm records

Macterm records a command when the shell reports that it finished (OSC 133). This needs [shell integration](/docs/configuration). The terminal gives Macterm the command as you typed it, from the cells of the prompt where you typed, at the moment the output starts. A command that clears the screen, such as `clear`, is recorded too, and a right prompt or an autosuggestion is not part of it. The output tail of a failed command comes from the screen after the next prompt shows. If Macterm cannot read the command, it records nothing. A tab that two windows show records each command one time.

Macterm does not record:

- A command that starts with a space. This is the `HISTCONTROL=ignorespace` convention of shells.
- The commands of the pinned tabs, the scratch tabs, the quick terminal and desktop widgets. These do not belong to a project.

Before Macterm stores a command or its output, it replaces secrets with `•••`. The panel does not run such a command again, because it would type the mask in place of the secret. These are values of names such as `TOKEN`, `SECRET`, `PASSWORD` and `API_KEY`, `Authorization` headers, `--password` options, passwords in URLs and keys with a known shape (GitHub, Slack, AWS). This filter cannot find every secret. To keep a command out of the records, start it with a space.

Each project keeps its 500 latest commands, in `~/Library/Application Support/Macterm/Memory/`.

## Git

Macterm reads the Git state of a local project when the panel shows it, and again as soon as the repository changes, for example when you switch branches in a pane, in your editor or in another terminal. It also reads it after a command finishes while a panel shows the project, when Macterm becomes the active app, and every 15 seconds while the panel shows and Macterm is active. Macterm does not fetch from the remote, so the number of commits behind the upstream changes only after a fetch, for example when you click **Pull**. Macterm uses the Git of Homebrew, or the Git of the Xcode Command Line Tools. If neither is installed, the panel shows no Git state. Macterm never opens the install dialog of the Command Line Tools.

For a remote project, Macterm's server on the host reads the Git state, with the same reads. The reads use the connection of the host's panes, so they need no login. When no pane of the host is connected, the panel keeps the last state that it read. A branch row types `cd` to the worktree on the host, or `git switch`, into the current pane, as for a local project.

## When you remove a project

When you remove a project, Macterm deletes its records too.
