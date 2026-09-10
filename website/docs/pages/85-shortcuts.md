<!-- page:
slug: shortcuts
title: Shortcuts and Spotlight
nav: Shortcuts
group: Automation
description: Drive Macterm from the Shortcuts app, Spotlight and Siri — projects, tabs, panes and keybinds as App Intents.
-->

# Shortcuts and Spotlight

Macterm publishes its actions as **App Intents**, so the Shortcuts app, Spotlight and Siri can drive it the way [the `macterm` CLI](/docs/cli) drives it from a script. The two surfaces do the same things through the same code — pick whichever fits: the CLI when you're already in a shell or writing an agent, Shortcuts when you want a keyboard-launchable action, a menu-bar button, or a step in a larger automation that also touches your calendar, your notes and your browser.

Everything here is off by default until you allow it once. See [Permission](#permission).

## Finding the actions

Open **Shortcuts**, create a shortcut, and search the action list for `Macterm`. The actions also appear in Spotlight — start typing an action's name and it shows up as a runnable result.

A few are offered up front as ready-made shortcuts, so you can run them without building anything: **Toggle Quick Terminal**, **Open Command Palette** and **New Tab**.

## The actions

### Projects

| Action | What it does |
| --- | --- |
| **New Project** | Takes a folder and adds it as a project, then selects it and brings the window forward. Optionally takes a name; without one it uses the folder's own name. If a [project file](/docs/declarative-layouts) declares that path, its layout applies — exactly as on a first open. |
| **Focus Project** | Shows a project. If a window is already on it, that window comes forward rather than the frontmost one being repointed. |

A project is created even when one already backs that folder — a directory is not an identity, and two projects on one folder stay fully separate.

### Tabs

| Action | What it does |
| --- | --- |
| **New Tab** | Opens a tab in a project you pick, and returns it so a later step can act on it. The optional **Command** runs in the new tab's shell as it starts. |
| **Focus Tab** | Selects a tab and brings its window forward. |
| **Close Tab** | Closes a tab and ends its sessions. |

**New Tab**'s command is typed into the shell as it launches — the same thing a layout's `run:` and `macterm tab new --run` do — so it goes through your login shell with your full environment. Write it so your own shell can parse it.

**Close Tab** refuses, with an error, if a pane in that tab has a running program. It never puts a confirmation dialog up, because a shortcut can run with nobody watching and a dialog nobody answers would stall the whole automation. Close it in the app if you meant to interrupt something. (Closing a [pinned tab](/docs/pinned-tabs) unloads it, as it does everywhere else: the row stays and the next launch starts it again.)

### Panes

| Action | What it does |
| --- | --- |
| **Run Command in Pane** | Types a command into a pane's shell. |
| **Send Key** | Sends one key chord — `ctrl+c`, `escape`, `up`, or a bare printable like `j`. |
| **Get Pane Contents** | Returns the text the pane is showing, optionally including scrollback. |
| **Get Pane Details** | Returns one of: ID, session name, working directory, foreground process, size. |
| **Focus Pane** | Shows a pane and puts the keyboard in it. |

**Run Command in Pane** has a **Submit** option, on by default. Turn it off and the text is left sitting on the prompt without running — useful to pre-fill a command line for yourself to look over, or to feed a full-screen program that decides for itself when input is complete.

**Send Key** is a separate action rather than an option on Run Command because it goes through a different path: it sends an encoded keypress, which is the only way to deliver something like `ctrl+c` that has no text form at all. It takes the same chord spelling as your [keybinds](/docs/configuration).

**Get Pane Contents** reads the terminal's own cells, so it sees what a full-screen program is drawing — not just output you could have piped.

All five need the pane's terminal to be live. A pane in a tab you have never selected has no terminal yet; select its tab once and the action works.

### The app

| Action | What it does |
| --- | --- |
| **Invoke Keybind** | Runs any of Macterm's own keybind actions, picked from a list. |
| **Toggle Quick Terminal** | Shows or hides the [quick terminal](/docs/quick-terminal). |
| **Open Command Palette** | Opens the [command palette](/docs/command-palette) in the frontmost window. |

**Invoke Keybind** is the catch-all: anything in the command palette that has a binding is in its list, under the same name — Split Right, Zoom Pane, Next Project, Save Layout, and so on. It returns true or false depending on whether the action applied, so a shortcut can branch on it rather than failing. (New Tab with no project open, for instance, simply doesn't apply.)

## Picking a project, tab or pane

Actions that act on something give you a picker. Type to filter it; a pane matches on the name you see in the sidebar *and* on its session name, so if you already have a session name in hand — from `macterm pane list`, or from `$MACTERM_SESSION` inside a pane — you can paste it straight in.

Panes are remembered by **session name**, which survives quitting and relaunching Macterm. So a shortcut you write today still names the same pane tomorrow, after the app has restarted and its sessions have reattached. Tabs and projects are remembered the same way.

If the thing a shortcut names has since gone — the tab was closed, the project removed — the action fails with a message saying so, rather than acting on something else.

## Permission

An intent can create projects and tabs, close tabs, and type into your shells, so **Settings → General → Shortcuts** gates the whole surface:

- **Ask** (the default) — the first action in each launch of Macterm puts up a confirmation. Your answer is remembered for the rest of that run, and asked again the next time Macterm starts.
- **Allow** — never asks.
- **Deny** — every action fails with an error saying where to change this.

Macterm mirrors Ghostty's `macos-shortcuts` here, including its `ask` default, but keeps it as a Macterm setting rather than a key in your ghostty config — see [Ghostty settings](/docs/ghostty) for where that line falls.

## Cold starts

Running a shortcut launches Macterm if it isn't running. The action waits for the app to finish starting — restoring your projects, tabs and sessions — and then does its work, so a shortcut fired at a machine that just booted behaves the same as one fired at an app that has been open for hours. If the app can't finish starting, the action fails with a message instead of hanging.
