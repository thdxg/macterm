<!-- page:
slug: explain-output
title: Explain Output
nav: Explain Output
group: Everyday use
description: Get a short explanation of the output of a command, or of selected text, from Apple Intelligence on your Mac.
-->

# Explain Output

Explain Output tells you what the output of a command means: what happened, whether it worked, and the cause of an error. If there is an error, it also gives the most likely fix. The explanation shows in a popover next to the text.

Apple Intelligence writes the explanation on your Mac. The text of the pane does not leave your Mac.

## Requirements

- macOS 26 or later.
- A Mac that supports Apple Intelligence.
- Apple Intelligence turned on in **System Settings → Apple Intelligence & Siri**.

On a Mac that cannot run Apple Intelligence, Explain Output does not show. If Apple Intelligence is off, the command palette tells you to turn it on.

## Explain the output of a command

1. Run a command in a pane.
2. Press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>E</kbd>, or right-click in the pane, then click **Explain Output**. You can also open the command palette and run **Explain Output**.

Macterm selects the last command and its output, so you can see what it explains. The explanation streams into the popover. The selection goes when you close the popover.

Macterm finds the output from the marks of the shell integration (OSC 133). Without shell integration, Macterm uses the text between the last two prompts, and selects nothing.

## Explain selected text

1. Select text in a pane, with the mouse or in [copy mode](/docs/copy-mode).
2. Press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>E</kbd>, or right-click the selection, then click **Explain Selection**. You can also run **Explain Output** from the command palette.

## The popover

- Press <kbd>Esc</kbd>, or click outside the popover, to close it. Closing it stops the explanation.
- Click **Copy** to copy the explanation.
- You can select text in the popover and press <kbd>⌘</kbd><kbd>C</kbd>.

The explanation is in the language of Macterm (**Settings → General → Language**).

## Change the keybind

The keybind is <kbd>⌘</kbd><kbd>⇧</kbd><kbd>E</kbd>. To change it, go to **Settings → Keymaps**, find **Explain Output** in the Panes group, and record a chord. <kbd>⌘</kbd><kbd>E</kbd> stays the Ghostty keybind that searches for the selected text.

## Long output

Apple Intelligence reads at most about 2,800 tokens of text. For a longer output, it reads the start and the end.
