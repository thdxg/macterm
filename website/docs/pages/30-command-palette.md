<!-- page:
slug: command-palette
title: Command palette
nav: Command palette
group: Everyday use
description: Drive Macterm from the keyboard with the ⌘P command palette.
-->

# Command palette

Press <kbd>⌘P</kbd>. One list searches everything:

- **Commands** — split, close, and focus panes; create, rename, and reorder tabs; toggle window chrome. Each row shows its current keybind.
- **Projects** — jump to, rename, or remove any project.

**To open a directory as a project**, type a path starting with `/` or `~`. The palette switches to path mode and autocompletes directories.

**To add a remote project**, type a spec like `devbox:~/dev/api`. See [remote projects](/docs/remote-projects).

**Some commands open a screen of their own** in the palette, named by a pill at the left of the input. <kbd>Esc</kbd>, or <kbd>Delete</kbd> with nothing typed, goes back to the full list. Each can have a shortcut of its own in Settings → Keymaps (none by default), which opens the palette straight on that screen and closes it when pressed again.

- **Password Manager** lists your saved passwords to type into the focused pane (see [passwords](/docs/passwords#typing-a-password-on-demand)).
- **Worktrees** lists the current project's linked git worktrees — those in the project's **Worktrees** menu in the sidebar, without the repository's main one — by branch, with each one's path relative to the project. Pick one to open a new tab there. It's also in the **Project** menu. It's unavailable when the project isn't a git repository (or is a remote project); its shortcut then says so instead.
