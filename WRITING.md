# Writing guide

This file holds the Macterm word list for ASD-STE100 text. Use it with the `asd-ste100` skill.
The skill gives the sentence rules. This file gives the terms.

Use one word for one thing in every file. Do not use a synonym to make the text less repetitive.

## Format

- Write the product name as **Macterm**.
- Write a label from the app in bold, exactly as the app shows it. For example, **Settings → Keymaps**.
- Write a key as `<kbd>`: <kbd>⌘P</kbd>.
- Write a command, a flag, a file name, a path and a setting key in code format.
- Speak to the reader as "you". Use the imperative for steps. Use the simple present for descriptions.
- Do not write "e.g.", "i.e.", "etc.", "via" or "&". Write "for example", "that is" or a plain list.
- Do not join two ideas with a dash or a semicolon. Write two sentences.
- Do not use a metaphor. Write "keeps running", not "survives". Write "stays", not "lives".

## Macterm terms

Define a term only when it is Macterm-specific or when it is ambiguous. Do not define a term that a reader can look up, such as `ssh`, `OSC` or `libghostty`.

| Term | Meaning |
|---|---|
| **project** | A folder, or a folder on a remote host. It has an entry in the sidebar. It holds tabs. |
| **tab** | One row under a project. It holds one or more panes. |
| **pane** | One terminal. A tab can have several panes. |
| **split** | The division of a tab into panes. As a verb, "split a pane" makes a new pane. |
| **session** | A shell that keeps running in the background, with its programs. Each pane has one session. Use "session" for this only. |
| **pinned tab** | A tab that belongs to no project. It sits above all projects. |
| **unload** | End the shells of a project or a pinned tab, but keep its row. |
| **layout** | A YAML file that lists the tabs, splits and commands of a project. |
| **remote project** | A project whose folder is on another machine. Its sessions run on that machine. |
| **quick terminal** | The drop-down terminal that you open with a global keybind. |
| **desktop widget** | A terminal that Macterm draws on the desktop. Compare **system widget**: a widget from macOS. |
| **palette** | The command palette, opened with <kbd>⌘P</kbd>. |
| **screen** | One list inside the palette. Do not use "screen" for a monitor. Write "display". |
| **extension** | A folder that you install. It adds one or more palettes. |
| **palette file** | A YAML file that defines one palette. |
| **mirror** | The copy of a tab in a second window. Its panes follow the real panes. |
| **CLI** | The `macterm` command. Write "the CLI". |
| **agent skill** | A text file that teaches a coding agent to use the CLI. Write "skill" only in this meaning. |
| **coding agent** | A program such as Claude Code that works in a terminal. Write "agent" after the first use. |
| **keybind** | A key combination that runs a command. Write "keybind". Do not write "shortcut", "hotkey" or "chord". |
| **Shortcuts** | The macOS app. Write "Shortcuts" only for that app. |

## Words to use

Each row has one word to use. The words in the second column have more than one meaning, or are hard to translate.

| Use | Do not use | Note |
|---|---|---|
| keep running | persist, survive | "Persist" and "survive" have other meanings. |
| disconnect, connect | detach, attach, reattach | These are `zmx` words. Write them only inside a command or a quotation. |
| connect again | reconnect, reattach | Use for a network drop and for a relaunch. |
| start | launch, spawn, run (for a program that begins) | Use "start" for a program, a shell, a session and the app. |
| run | execute, invoke | Use "run" for a command. |
| open | launch, bring up | Use "open" for a window, a tab, a file, the palette and a folder. |
| close | kill, terminate, end (for a pane) | "Close" is what the user does to a pane, tab, window or project. |
| end | kill, terminate | Use "end" for a session or a program. Write "kill" only inside `zmx kill`. |
| quit | exit (for the app) | Use "quit" for Macterm. Use "exit" for a shell. |
| select | choose, pick | Use "select" for a tab, a project or a row. Keep "Pick" only inside an app label. |
| focus | activate | A focused pane receives your keys. |
| bring forward | front, raise | Use for a window. |
| terminal | surface | "Surface" is a code word. |
| full-screen program | TUI | The app label **Pass to TUI** stays until the app text changes. |
| shell prompt | prompt (alone) | Always write "shell prompt" or "password prompt". |
| permission request | prompt (for macOS) | For example, a Local Network permission request. |
| command | action | Use "action" only for an App Intent in Shortcuts, and for the `action:` key in a palette file. |
| grid cell | cell | Use "character cell" for a cell in a terminal. |
| display | screen, monitor | |
| folder | directory | Use "directory" only in a file path, a key name or a command. |
| setting | option, preference | |
| Settings | Preferences | |
| use | utilize, leverage | |
| because | since (for a cause) | "Since" can mean a time. |
| with, over | via, through | |
| for example | e.g. | |

## Check

Run the linter on this file with `--disable synonym-rotation`. The word tables name the words to avoid, so the check reports them.

## When the app text and the docs disagree

Phase 3 of the rewrite keeps every app label as it is. Phase 4 changes an app label only when this list says to. When a label changes, update every page that names it in the same pull request.
