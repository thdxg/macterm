<!-- page:
slug: command-palette
title: Command palette
nav: Command palette
group: Everyday use
description: Drive Macterm from the keyboard with the ⌘P command palette.
-->

# Command palette

Press <kbd>⌘P</kbd>. One list searches everything:

- **Palettes** — the screens below, the first section after your recent projects: a row with an icon and a chevron opens one in place.
- **Commands** — split, close, and focus panes; create, rename, pin, and switch tabs; toggle window chrome. Each row shows its current keybind.
- **Projects** — jump to any project, your recent ones listed first with nothing typed. Rename, unload, or remove the current one with its commands.

**To open a directory as a project**, type a path starting with `/` or `~`. The palette switches to path mode and autocompletes directories.

**To add a remote project**, type a spec like `devbox:~/dev/api`. See [remote projects](/docs/remote-projects).

**Some commands open a screen of their own** in the palette, named by a pill floating above the palette; in the list, such a row shows the screen's icon and a chevron. Screens can open screens, and the pills then read as a trail, root first — click one to go back to it. <kbd>Esc</kbd>, or a fresh press of <kbd>Delete</kbd> with nothing typed, goes back one screen (a Delete held down to clear the search stops at the empty field). A screen that has to wait for its list shows a spinner meanwhile; one whose list failed says why, with a Retry button (also <kbd>⌘R</kbd>). **Some rows have a second action** under <kbd>⌥</kbd>: hold it and the row's subtitle names what <kbd>⌥↩</kbd> (or an ⌥-click) does. Each can have a shortcut of its own in Settings → Keymaps, under **Palettes** beside <kbd>⌘P</kbd> itself (none by default), which opens the palette straight on that screen. Pressed again on that screen, it closes the palette; pressed on another screen, it goes to that one.

- **Password Manager** lists your saved passwords to type into the focused pane (see [passwords](/docs/passwords#typing-a-password-on-demand)).
- **Files** lists the current project's files and directories, searched by name or partial path (`pal/eng` finds `Palette/PaletteEngine.swift`). Pick one to open it in a split beside the focused pane, or a new tab when the project has none — a directory as a shell there, a file in your terminal editor (see [Text Files](/docs/configuration#open-files-in-your-terminal-editor)); hold <kbd>⌥</kbd> to open it with its default app instead. Dependency and build folders (`node_modules`, `build`, …) and hidden entries are left out. Unavailable for remote projects.
- **Worktrees** lists the current project's linked git worktrees — those in the project's **Worktrees** menu in the sidebar, without the repository's main one — by branch, with each one's path relative to the project. Pick one to open a new tab there. It's also in the **Project** menu. It's unavailable when the project isn't a git repository (or is a remote project); its shortcut then says so instead.

## Custom palettes

Your own screens, from YAML files in `~/.config/macterm/palettes/`, one file per palette. A command's output becomes searchable rows, and each row opens another screen or runs a command in a new tab or split. A Kubernetes palette, for example, goes from namespaces to pods to a pod's logs. Each one sits in the **Palettes** section beside the built-in screens.

See [custom palettes](/docs/custom-palettes) for the file format and examples, and the [cookbook](/docs/cookbook#kubernetes-palette) for a complete Kubernetes palette.

## Settings → Palettes

Every palette as a card in a searchable grid, in three groups:

- **Built-in** — Password Manager, Worktrees and Files.
- **Installed** — your [custom palettes](/docs/custom-palettes): the files in `~/.config/macterm/palettes/` and the extensions you installed, in `~/.config/macterm/extensions/`. One that doesn't read shows a warning beside its switch.
- **Available** — extensions from [Macterm's repository](https://github.com/thdxg/macterm/tree/main/extensions) you haven't installed, for your version of Macterm, each with its authors. **Install** shows its README and every file in it — its commands run on your Mac — and then copies the folder into `~/.config/macterm/extensions/`, where its palette is installed like any other.

Built-in and installed palettes have a switch. A screen turned off leaves the palette's list and its menu; its keybind, if it has one, says so instead of reaching the terminal, and stays bound for when the screen comes back. The available extensions are read when you open the pane, at most once an hour; **Refresh** reads them again.
