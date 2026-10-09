<!-- page:
slug: command-palette
title: Command palette
nav: Command palette
group: Everyday use
description: Use Macterm from the keyboard with the ⌘P command palette.
-->

# Command palette

Press <kbd>⌘P</kbd>. One list searches everything:

- **Palettes**: the screens below. This is the first section after your recent projects. A row with an icon and a chevron opens a screen in the same place.
- **Commands**: split, close and focus panes. Create, rename, pin and switch tabs. Show or hide parts of the window. Each row shows its current keybind.
- **Projects**: go to any project. With nothing typed, the recent projects are first. Rename, unload or remove the current project with its commands.

**To open a folder as a project**, type a path that starts with `/` or `~`. The palette changes to path mode and completes folder names.

**To add a remote project**, type a spec such as `devbox:~/dev/api`. See [remote projects](/docs/remote-projects).

Some commands open a screen of their own in the palette. A pill above the palette names the screen. In the list, a row for such a screen shows the icon of the screen and a chevron. A screen can open another screen. The pills then show a trail, with the root first. Click a pill to go back to it. Press <kbd>Esc</kbd> to go back one screen. You can also press <kbd>Delete</kbd> with nothing typed. A held <kbd>Delete</kbd> clears the search and stops at the empty field.

A screen that must wait for its list shows a spinner. If the list fails, the screen says why and shows a Retry button. <kbd>⌘R</kbd> also retries.

**Some rows have a second action** under <kbd>⌥</kbd>. Hold the key. The subtitle of the row then names what <kbd>⌥↩</kbd> (or an ⌥-click) does.

Each screen can have its own keybind in Settings → Keymaps, under **Palettes**, next to <kbd>⌘P</kbd>. No screen has a keybind by default. The keybind opens the palette on that screen. Press it again on that screen to close the palette. Press it on another screen to go to its screen.

- **Password Manager** lists your saved passwords. Select one to type it into the focused pane (see [passwords](/docs/passwords#typing-a-password-on-demand)).
- **Files** lists the files and directories of the current project. Search by name or by part of a path (`pal/eng` finds `Palette/PaletteEngine.swift`). Select one to open it in a split next to the focused pane. If the project has no pane, it opens in a new tab. A directory opens as a shell there. A file opens in your terminal editor (see [Text Files](/docs/configuration#open-files-in-your-terminal-editor)). Hold <kbd>⌥</kbd> to open it with its default app. The list leaves out dependency and build folders (`node_modules`, `build` and others) and hidden entries. Remote projects do not have this screen.
- **Worktrees** lists the linked git worktrees of the current project, as in the **Worktrees** menu in the sidebar. The main worktree of the repository is not in the list. Each row shows the branch and the path relative to the project. Select a row to open a new tab there. The **Project** menu has the same command. It is not available when the project is not a git repository, or when it is a remote project. Its keybind then says why.

## Extensions

Extensions add screens. You can install an extension from the Macterm repository, or write your own extension in `~/.config/macterm/extensions/`. Each palette of an extension is a YAML file. The output of a command becomes rows that you can search. Each row opens another screen, or runs a command in a new tab or split. For example, a Kubernetes palette goes from namespaces to pods to the logs of a pod. Each palette is in the **Palettes** section, next to the built-in screens.

See [extensions](/docs/extensions) for the file format and examples. The [cookbook](/docs/cookbook#kubernetes-palette) has a complete Kubernetes palette.

## Settings → Extensions

Settings shows every [extension](/docs/extensions) as a card in one grid that you can search by name. The grid has the extensions that you installed, in `~/.config/macterm/extensions/`. It also has the extensions in [the Macterm repository](https://github.com/thdxg/macterm/tree/main/extensions) that you did not install. The installed extensions come first, and each group is in order of name. To show only one group, use the menu next to the search field: **All**, **Installed** or **Not Installed**. A card shows the name and the description of the extension. An extension can bring several palettes. Each card has one button:

- **Install** copies the folder of the extension into `~/.config/macterm/extensions/` at once. The extension is then installed like any other extension. Its commands run on your Mac, so read it first. The book button next to **Install** opens the extension on GitHub. You see every file that it installs, and its README.
- **Installed** offers to move the extension to the Trash.

If an extension has a file that Macterm cannot read, its card shows a warning. Macterm reads the extensions of the repository when you open the pane, at most one time each hour. They do not depend on your version of Macterm. An extension that works keeps working after every update. If an extension needs a newer Macterm, the card says so. You can install it after you update. The built-in screens (Password Manager, Worktrees and Files) are not extensions and are not in the list.
