<!-- page:
slug: shortcuts
title: Shortcuts and Spotlight
nav: Shortcuts
group: Automation
description: Control Macterm from the Shortcuts app, Spotlight and Siri. Projects, tabs, panes and keybinds are App Intents.
-->

# Shortcuts and Spotlight

Macterm makes its actions available as App Intents. Shortcuts, Spotlight and Siri can use them to control Macterm. They have the same capabilities as [the CLI](/docs/cli). Use the CLI from a shell or a script. Use Shortcuts for an action that you start from the keyboard, or for a step in a larger automation.

**Allow Macterm first.** See [Permission](#permission).

## Finding the actions

Open **Shortcuts**, create a shortcut, and search the action list for `Macterm`. The actions are in Spotlight too. Three actions are ready-made: **Toggle Quick Terminal**, **Open Command Palette** and **New Tab**.

## Projects

| Action | What it does |
| --- | --- |
| **New Project** | Adds a folder as a project, selects it and brings the window forward. The name is optional. The default is the name of the folder. `Pinned` is a reserved name. Macterm refuses it, and it adds a folder with the name Pinned as `Pinned 2`. The action always creates a new project, also when a project already has that folder. |
| **Focus Project** | Shows a project. A window that already shows the project comes forward. |

## Tabs

| Action | What it does |
| --- | --- |
| **New Tab** | Opens a tab in a project that you select. It returns the tab for a later step. The optional **Command** runs in the new shell. |
| **Focus Tab** | Selects a tab and brings its window forward. |
| **Close Tab** | Closes a tab and ends its sessions. If a pane has a running program, the action fails with an error. It never shows a dialog. |

The command of **New Tab** goes through your login shell, like the `run:` of a layout. Write it so that your shell can parse it.

## Panes

| Action | What it does |
| --- | --- |
| **Run Command in Pane** | Types a command into the shell of a pane. **Submit** is on by default. Turn it off to leave the text at the shell prompt. |
| **Send Key** | Sends one key combination: `ctrl+c`, `escape`, `up` or a single printable key. The spelling is the same as for your [keybinds](/docs/configuration). |
| **Get Pane Contents** | Returns the text that the pane shows. It can include the scrollback. It reads the cells of the terminal, so it sees full-screen programs. |
| **Get Pane Details** | Returns one of these: ID, session name, working directory, foreground process, size. |
| **Focus Pane** | Shows a pane and puts the keyboard in it. |

All five actions need a live terminal. A pane in a tab that you never selected has no live terminal. Select that tab one time.

## The app

| Action | What it does |
| --- | --- |
| **Invoke Keybind** | Runs any keybind action of Macterm. You select it from a list. It returns true or false, so a shortcut can branch on the result. |
| **Toggle Quick Terminal** | Shows or hides the [quick terminal](/docs/quick-terminal). |
| **Open Command Palette** | Opens the [palette](/docs/command-palette) in the frontmost window. |

## Picking a project, tab or pane

Type to filter the picker. A pane matches the name in the sidebar *and* its session name. You can paste a session name from `macterm pane list` or `$MACTERM_SESSION`.

Macterm remembers panes, tabs and projects with identifiers that stay the same after you quit and start Macterm again. A shortcut that you write today therefore names the same pane tomorrow. If the target is gone, the action fails with a message. It does not act on something else.

## Permission

The key `macos-shortcuts` in your Ghostty config controls access to all actions.

```ini
macos-shortcuts = allow
```

| Value | Effect |
| --- | --- |
| `ask` | The default. The first action in each run of Macterm asks you. Your answer holds until Macterm quits. |
| `allow` | Never asks. |
| `deny` | Every action fails with an error. |

Macterm reads the key live, so **Reload Ghostty Config** applies a change with no restart.

## Cold starts

When you run a shortcut and Macterm is not running, the shortcut starts Macterm. The action waits until Macterm finishes its restore. Then it does its work. If Macterm cannot finish its start, the action fails. It does not wait forever.
