<!-- page:
slug: extensions
title: Extensions
nav: Extensions
group: Extensions
description: Add screens to the command palette with extensions. Install them from the Macterm repository or write your own in YAML. The output of a command becomes rows that you can search. Each row opens another screen or runs a command.
-->

# Extensions

An extension adds to what Macterm can do. Today, an extension adds screens to the [command palette](/docs/command-palette): Git branches and worktrees, Docker containers, SSH hosts, Kubernetes pods, and anything that a command can list. Install an extension from **Settings → Extensions** (see [sharing an extension](#sharing-an-extension)), or write your own. Each extension brings one or more palettes. Each palette appears in the **Palettes** section of the command palette, with a chevron. When you select it, its screen opens in the same place.

An extension is a folder in `~/.config/macterm/extensions/`. The folder has an `extension.yaml` file and a `palettes/` folder with one YAML file for each palette. Macterm reads the folder again each time that the palette opens. When you save a file, that is all that you do. You do not reload or restart anything.

This page shows how to make an extension and how to share it. The [palette reference](/docs/extension-palettes) gives every key of a palette file. The [examples](/docs/extension-examples) are complete palettes that you can copy.

> Earlier versions of Macterm also read palette files in `~/.config/macterm/palettes/`. Macterm does not read that folder now. To keep a palette from it, put the file in the `palettes/` folder of an extension.

## A first extension

Make the folder `~/.config/macterm/extensions/git/`. Put an `extension.yaml` file in it, which gives the name and the description of the extension:

```yaml title="~/.config/macterm/extensions/git/extension.yaml"
# yaml-language-server: $schema=https://raw.githubusercontent.com/thdxg/macterm/main/assets/extension.schema.json
name: Git
description: Switch to, log or diff the branches of the project
icon: arrow.triangle.branch
```

Then put the palette in `palettes/`:

```yaml title="~/.config/macterm/extensions/git/palettes/git.yaml"
# yaml-language-server: $schema=https://raw.githubusercontent.com/thdxg/macterm/main/assets/palette.schema.json
name: Git
description: The current project's branches
root: branches
nodes:
  branches:
    list: git branch --format='%(refname:short)'
    export: { BRANCH: . }
    enter: branch
  branch:
    items:
      - { title: Switch to it, action: { run: git switch "$BRANCH", in: split } }
      - { title: Log, action: { run: git log --oneline --graph "$BRANCH", in: split } }
      - { title: Diff against HEAD, action: { run: git diff HEAD..."$BRANCH", in: split } }
```

Press <kbd>⌘P</kbd>, type `git` and press <kbd>Return</kbd>. The screen lists the branches of the active project. Select a branch. A second screen shows what you can do with it. The pills above the palette read **Git › main**. Select **Log**. `git log` runs in a split next to the focused pane.

The [palette reference](/docs/extension-palettes) tells what each key of this file does.

## The extension file

`extension.yaml` has these keys:

| Key | |
| --- | --- |
| `name` | Required. The name on the card of the extension in Settings → Extensions. |
| `description` | Required. One line on its card that says what the extension is for. |
| `icon` | The icon of its card and of the row and the pill of each of its palettes. Give the name of an [SF Symbol](https://developer.apple.com/sf-symbols/), or the path of a PNG file in the extension folder, for example `icon.png`. See [Icon files](#icon-files). The default is `puzzlepiece.extension`. |
| `authors` | The GitHub usernames of the people who maintain it. An extension in the Macterm repository must have them. An extension that you write for yourself does not need them. |

### Icon files

An extension can bundle its own icon in place of an SF Symbol. Put a PNG file in the extension folder, and give its path in `icon`:

```yaml title="~/.config/macterm/extensions/git/extension.yaml"
name: Git
description: Switch to, log or diff the branches of the project
icon: icon.png
```

The file must be a PNG of exactly 128×128 pixels. Macterm draws it as a template image, as it draws an SF Symbol. The alpha channel is the shape, and the color comes from the theme. Thus, use a single shape on a transparent background. Colors in the file are not shown.

If the file is missing or has a different size, Macterm shows the default icon. The card of the extension in Settings → Extensions then shows a warning with the reason. An extension in the Macterm repository with such an icon cannot be installed. When you change the file, Macterm shows the new icon the next time that you open the palette.

## Keybinds and Settings

- **Settings → Extensions** lists every extension in one grid, installed or not. On a card, **Installed** offers to uninstall the extension. The prompt names the features that go with it. **Uninstall** moves its folder to the Trash. This is how you remove an extension.
- **Settings → Keymaps** has an **Extensions** group at the bottom. It has a row for every palette of your extensions. No palette has a keybind by default. The keybind of a palette opens the command palette on that palette. Press it again on the first screen of the palette to close the command palette. Press it on a deeper screen to go back to that first screen.
- **Any palette keybind can be Global or Pass to TUI.** This applies to built-in palettes and to the palettes of extensions. These are the two options in the **⋯** menu of its row. A **Global** keybind works from any app. It brings the window of Macterm forward with the palette open on it. **Pass to TUI** gives the keybind to the program in the focused pane when that program is in your list under Passthrough Programs.

## Sharing an extension

Anyone can install the extensions in **Settings → Extensions**. They are folders in [`extensions/`](https://github.com/thdxg/macterm/tree/main/extensions) in the Macterm repository. Each folder has `extension.yaml` (its name, description and authors), a `README.md`, and its palettes in `palettes/`. An extension can have as many palettes as it needs. Each palette has its own name and description. An installed extension is in `~/.config/macterm/extensions/<id>/`. Its commands find the other files of the folder through `$MACTERM_EXTENSION_DIR`. An example is a script that is too long for the YAML. In the CLI, its palettes have the names `<extension>/<file>`. They never clash with a palette file of your own.

### Updates

An installed extension is your copy. You can change it in the same way as an extension that you wrote. Macterm never changes it by itself.

When you install an extension, Macterm records each of its files in a hidden file in its folder, `.source.json`. When Settings → Extensions opens, Macterm compares your copy with that record and with the version in the repository:

- **The repository changed the extension, and you did not change your copy.** The card shows an Update button (<kbd>↓</kbd> in a filled circle). Click it to get the new version.
- **You changed your copy, and the repository did not change the extension.** The card shows no Update button. Your copy stays as it is.
- **You changed your copy, and the repository also changed the extension.** The card shows the Update button. Before it updates, Macterm asks you. Your changed copy goes to the Trash.
- **The folder has no `.source.json`.** This is an extension that you wrote, copied by hand, or installed with an older version of Macterm. If it is the same as the version in the repository, Macterm writes the record. If it is different, the Update button asks before it puts your copy in the Trash.

**Update extensions automatically** in Settings → Extensions is on by default. Macterm checks the repository when it starts and one time each day. It updates only the extensions that you did not change. A message names each extension that it updated. An extension that you changed, or one without `.source.json`, still waits for you to click its Update button. An extension runs commands on your Mac. To get each update only when you click, turn off **Update extensions automatically**.

An update moves the old folder to the Trash. To undo an update, put the old folder back. To keep a copy as your own, delete its `.source.json`. If you do not change the copy, Macterm then asks before each update.

An extension can include screenshots for its README. **Capture Palette** takes them at the one size that the repository accepts. It frames the command palette in the same way each time. Bind it in Settings → Keymaps and press it while the palette is open on the screen that you want. If you run it from the menu or from the palette, it captures the first screen of the palette. The first time, macOS asks if Macterm can record the screen. If the Screen Recording switch for Macterm is already on and macOS asks again, the switch belongs to a build with a different signature. Remove Macterm from the list, then try again. An update keeps the permission.

To add your extension, open a pull request with the folder. You do not need to clone the whole repository. [The README of the folder](https://github.com/thdxg/macterm/blob/main/extensions/README.md) says how to do it. It also says what an extension needs: POSIX commands, a `requires:`, and a `when:` where the extension cannot always work. Macterm reads every extension there with its validator before the extension merges.

## Writing one with a coding agent

Macterm has a skill that teaches coding agents this format. Print it with this command:

```sh
macterm skills macterm-palettes
```

See [skills for coding agents](/docs/cli#skills-for-coding-agents). The schema is at [`assets/palette.schema.json`](https://raw.githubusercontent.com/thdxg/macterm/main/assets/palette.schema.json) for editors that understand `yaml-language-server`. The comment at the top of the first example points an editor to it.
