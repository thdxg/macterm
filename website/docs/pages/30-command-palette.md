<!-- page:
slug: command-palette
title: Command palette
nav: Command palette
group: Everyday use
description: Drive Macterm from the keyboard with the ⌘P command palette.
-->

# Command palette

Press <kbd>⌘P</kbd>. One list searches everything:

- **Palettes** — the screens below, first in the list: a row with an icon and a chevron opens one in place.
- **Commands** — split, close, and focus panes; create, rename, and reorder tabs; toggle window chrome. Each row shows its current keybind.
- **Projects** — jump to, rename, or remove any project.

**To open a directory as a project**, type a path starting with `/` or `~`. The palette switches to path mode and autocompletes directories.

**To add a remote project**, type a spec like `devbox:~/dev/api`. See [remote projects](/docs/remote-projects).

**Some commands open a screen of their own** in the palette, named by a pill floating above the palette; in the list, such a row shows the screen's icon and a chevron. Screens can open screens, and the pills then read as a trail, root first — click one to go back to it. <kbd>Esc</kbd>, or <kbd>Delete</kbd> with nothing typed, goes back one screen. A screen that has to wait for its list shows a spinner meanwhile; one whose list failed says why, with a Retry button (also <kbd>⌘R</kbd>). **Some rows have a second action** under <kbd>⌥</kbd>: hold it and the row's subtitle names what <kbd>⌥↩</kbd> (or an ⌥-click) does. Each can have a shortcut of its own in Settings → Keymaps, under **Palettes** beside <kbd>⌘P</kbd> itself (none by default), which opens the palette straight on that screen and closes it when pressed again.

- **Password Manager** lists your saved passwords to type into the focused pane (see [passwords](/docs/passwords#typing-a-password-on-demand)).
- **Files** lists the current project's files and directories, searched by name or partial path (`pal/eng` finds `Palette/PaletteEngine.swift`). Pick one to open it in a split beside the focused pane — a directory as a shell there, a file in your terminal editor (see [Text Files](/docs/configuration#open-files-in-your-terminal-editor)); hold <kbd>⌥</kbd> to open it with its default app instead. Dependency and build folders (`node_modules`, `build`, …) and hidden entries are left out. Unavailable for remote projects.
- **Worktrees** lists the current project's linked git worktrees — those in the project's **Worktrees** menu in the sidebar, without the repository's main one — by branch, with each one's path relative to the project. Pick one to open a new tab there. It's also in the **Project** menu. It's unavailable when the project isn't a git repository (or is a remote project); its shortcut then says so instead.

## Custom palettes

Your own screens, from YAML files in `~/.config/macterm/palettes/` — one file per palette, read again every time the palette opens. A palette is a set of named **nodes**. A node is either a **menu** (`items:`, rows you write) or a **listing** (`list:`, a command whose output becomes rows). Every row either **enters** another node or performs an **action**, and can **export** values that follow you down the screens as environment variables.

```yaml
# ~/.config/macterm/palettes/kubernetes.yaml
name: Kubernetes
icon: shippingbox
description: Namespaces, pods and their logs
root: menu
nodes:
  menu:
    items:
      - { title: Namespaces, enter: namespaces }
      - { title: Pods, subtitle: All namespaces, enter: pods }
  namespaces:
    list: kubectl get ns -o json
    rows: .items
    title: .metadata.name
    export: { NAMESPACE: .metadata.name }
    enter: namespace-menu
  namespace-menu:
    items:
      - { title: Pods, enter: pods }
      - { title: Set as current context, action: { run: kubectl config set-context --current --namespace "$NAMESPACE" } }
  pods:
    list: kubectl get pods ${NAMESPACE:+-n "$NAMESPACE"} ${NAMESPACE:--A} -o json
    rows: .items
    title: .metadata.name
    subtitle: .status.phase
    match: [.metadata.name, .metadata.namespace, .metadata.labels.app]
    export: { POD: .metadata.name, NAMESPACE: .metadata.namespace }
    action: { run: kubectl logs -f -n "$NAMESPACE" "$POD", in: split }
```

The rules, each one a line in the file:

- **Commands run in your login shell** (`$SHELL -l -c`), in the active project's directory, so they are written in your shell's syntax and see its `PATH`. Every command gets `MACTERM_PROJECT_DIR` and `MACTERM_PROJECT_NAME`, plus whatever the rows above exported — `kubectl get pods -n "$NAMESPACE"` reads a variable; nothing is ever pasted into a command's text, so a value with spaces or quotes can't break it. The same node can be reached from two places (`pods` above, with and without a namespace) and the command tells them apart the way a shell does.
- **A shell that prints on startup prints into the rows.** The listing runs in a login shell, so a greeting in your rc file becomes a row; keep startup quiet, or wrap the command so it prints last.
- **A listing's output** is JSON — an array, newline-delimited objects (`jq -c '.items[]'`), or an object with the rows at `rows:` — or, when it doesn't start like JSON, plain lines, one row each. In a listing node a value starting with `.` is a path into the row (`.` is the row itself, `.metadata.name` a field, `.items[0].name` an index); anything else is literal. `title:` defaults to `.`, `match:` to the title and subtitle. Inside a `{ }` mapping, quote a path with an index (`PORT: '.spec.ports[0].port'`), or YAML reads the brackets as a list.
- **A row that `enter:`s** names the new screen's pill after itself: the trail reads **Kubernetes › prod › Pods**. Backspace with nothing typed, or Escape, goes back one screen; clicking a pill goes back to it.
- **An action is exactly one of** `run:` (typed into a new tab, or a split with `in: split`, with the exported variables in its environment), `copy:` (to the clipboard) or `open:` (a URL or file, with its default app).
- **While a listing runs** the screen shows a spinner; **if it fails** — command not found, a non-zero exit, output that isn't the shape asked for — the screen says why, with the command's stderr, and **Retry** (also <kbd>⌘R</kbd>) runs it again. A listing that takes more than 30 seconds is given up on.
- **A file that doesn't read** keeps its row, with a warning glyph before the chevron; entering it shows the error, and <kbd>⌘R</kbd> reads the file again once it is fixed. Settings → Palettes shows the same warning beside its switch.
- **Keybind** any palette in Settings → Keymaps under **Palettes**; its chord opens the command palette straight on it. Custom palettes' chords work inside Macterm only.

A schema for editors that understand `yaml-language-server` is at [`assets/palette.schema.json`](https://raw.githubusercontent.com/thdxg/macterm/main/assets/palette.schema.json). Coding agents can write a palette for you: `macterm skills` prints a skill that teaches the format.

## Settings → Palettes

Every screen the palette can open, built-in and custom, each with a switch, and the custom palettes' folder. A screen turned off leaves the palette's list and its menu; its keybind, if it has one, says so instead of reaching the terminal, and stays bound for when the screen comes back.
