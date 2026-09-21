<!-- page:
slug: shortcuts
title: Shortcuts and Spotlight
nav: Shortcuts
group: Automation
description: Drive Macterm from the Shortcuts app, Spotlight and Siri — projects, tabs, panes and keybinds as App Intents.
-->

# Shortcuts and Spotlight

Macterm publishes its actions as App Intents, so Shortcuts, Spotlight and Siri can drive it. Same capabilities as [the CLI](/docs/cli) — use the CLI from a shell or a script, Shortcuts for a keyboard-launchable action or a step in a larger automation.

**Allow it first.** See [Permission](#permission).

## Finding the actions

Open **Shortcuts**, create a shortcut, and search the action list for `Macterm`. They appear in Spotlight too. Three are offered ready-made: **Toggle Quick Terminal**, **Open Command Palette**, and **New Tab**.

## Projects

| Action | What it does |
| --- | --- |
| **New Project** | Adds a folder as a project, selects it, and brings the window forward. Optional name; defaults to the folder's. Always creates a new project, even if one already backs that folder. |
| **Focus Project** | Shows a project. A window already on it comes forward. |

## Tabs

| Action | What it does |
| --- | --- |
| **New Tab** | Opens a tab in a project you pick and returns it for a later step. The optional **Command** runs in the new shell. |
| **Focus Tab** | Selects a tab and brings its window forward. |
| **Close Tab** | Closes a tab and ends its sessions. Fails with an error if a pane has a running program — never puts up a dialog. |

**New Tab**'s command goes through your login shell, like a layout's `run:`. Write it so your shell can parse it.

## Panes

| Action | What it does |
| --- | --- |
| **Run Command in Pane** | Types a command into a pane's shell. **Submit** is on by default; turn it off to leave the text on the prompt. |
| **Send Key** | Sends one chord — `ctrl+c`, `escape`, `up`, or a bare printable. Same spelling as your [keybinds](/docs/configuration). |
| **Get Pane Contents** | Returns the text the pane is showing, optionally with scrollback. Reads the terminal's cells, so it sees full-screen programs. |
| **Get Pane Details** | Returns one of: ID, session name, working directory, foreground process, size. |
| **Focus Pane** | Shows a pane and puts the keyboard in it. |

All five need a live terminal. A pane in a tab you have never selected has none — select its tab once.

## The app

| Action | What it does |
| --- | --- |
| **Invoke Keybind** | Runs any of Macterm's keybind actions, picked from a list. Returns true or false, so a shortcut can branch on it. |
| **Toggle Quick Terminal** | Shows or hides the [quick terminal](/docs/quick-terminal). |
| **Open Command Palette** | Opens the [palette](/docs/command-palette) in the frontmost window. |

## Picking a project, tab or pane

Type to filter the picker. A pane matches on the name in the sidebar *and* on its session name, so you can paste one from `macterm pane list` or `$MACTERM_SESSION`.

Panes, tabs and projects are remembered by identifiers that survive quitting and relaunching, so a shortcut written today names the same pane tomorrow. If the target is gone, the action fails with a message rather than acting on something else.

## Permission

`macos-shortcuts` in your Ghostty config gates the whole surface.

```ini
macos-shortcuts = allow
```

| Value | Effect |
| --- | --- |
| `ask` | Default. The first action in each launch asks; your answer holds for that run. |
| `allow` | Never asks. |
| `deny` | Every action fails with an error. |

Read live, so **Reload Ghostty Config** applies a change without a restart.

## Cold starts

Running a shortcut launches Macterm if it isn't running, and the action waits for the restore to finish before doing its work. If the app can't finish starting, the action fails rather than hanging.
