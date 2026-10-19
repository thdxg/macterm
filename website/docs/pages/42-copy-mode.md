<!-- page:
slug: copy-mode
title: Copy Mode
nav: Copy Mode
group: Everyday use
description: Move through the scrollback and select text with the keyboard, with the keys of Helix. This page lists the keys and says how to change the keybind.
-->

# Copy Mode

Copy mode lets you move through the scrollback and select text with the keyboard. It is the copy mode of tmux and the vi mode of Alacritty, with the keys of Helix.

Press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>Space</kbd> in a pane to start it. A block cursor appears at the terminal cursor, and a **Copy Mode** pill appears in the corner of the pane. A click on the pill also leaves the mode. Press <kbd>Esc</kbd> to leave it. The pane types into the shell again.

While copy mode is on, the keys of the pane move the selection and do not reach the shell. <kbd>⌘</kbd> keys still work: <kbd>⌘</kbd><kbd>C</kbd> copies the selection, <kbd>⌘</kbd><kbd>W</kbd> closes the pane.

## The model

Copy mode uses the model of Helix. There is always a selection. Its **head** is the cursor, the end that the motions move. Its **anchor** is the other end.

- In **normal mode**, a motion moves the head and puts the anchor on it. The selection is one cell: a cursor.
- In **select mode**, a motion moves the head and keeps the anchor. The selection grows or shrinks. Press <kbd>v</kbd> to start select mode. The pill says **Select Mode**. Press <kbd>v</kbd> or <kbd>Esc</kbd> to go back to normal mode.
- The word motions <kbd>w</kbd>, <kbd>e</kbd> and <kbd>b</kbd> select the text that they move over, in normal mode too, as in Helix.

## Keys

| Key | Motion |
|---|---|
| <kbd>h</kbd> <kbd>j</kbd> <kbd>k</kbd> <kbd>l</kbd>, arrows | One cell left or right, one row up or down |
| <kbd>w</kbd> | To the start of the next word |
| <kbd>e</kbd> | To the end of the word |
| <kbd>b</kbd> | To the start of the word |
| <kbd>g</kbd><kbd>h</kbd> <kbd>g</kbd><kbd>l</kbd>, <kbd>Home</kbd> <kbd>End</kbd> | The start of the row, the last character of the row |
| <kbd>g</kbd><kbd>g</kbd> <kbd>g</kbd><kbd>e</kbd> | The top of the scrollback, the last character on the screen |
| <kbd>⌃</kbd><kbd>u</kbd> <kbd>⌃</kbd><kbd>d</kbd> | Half a screen up or down |
| <kbd>⌃</kbd><kbd>b</kbd> <kbd>⌃</kbd><kbd>f</kbd>, <kbd>Page Up</kbd> <kbd>Page Down</kbd> | A screen up or down |

A number before a motion repeats it: <kbd>5</kbd><kbd>j</kbd> moves down five rows.

| Key | Selection |
|---|---|
| <kbd>v</kbd> | Start or stop select mode |
| <kbd>x</kbd> | Select the whole line. Press it again to add the next line |
| <kbd>%</kbd> | Select everything |
| <kbd>;</kbd> | Collapse the selection to the head |
| <kbd>⌥</kbd><kbd>;</kbd> | Swap the anchor and the head |
| <kbd>y</kbd> | Copy the selection to the clipboard and leave copy mode |
| <kbd>/</kbd> | Open the search bar. The match becomes the selection |
| <kbd>n</kbd> <kbd>N</kbd> | The next or the previous match |
| <kbd>Esc</kbd> | Leave select mode, then leave copy mode |

A word is a run of letters, or a run of punctuation. Spaces and the end of a line separate words. The characters in the Ghostty key `selection-word-chars` count as punctuation.

The mouse still works. A drag makes a selection, and the next motion continues from it.

## The keybind

**Copy Mode** is a row in Settings → Keymaps. Change its keys there. It is also in the command palette and in the View menu.

For now, you cannot change the keys inside copy mode. A later version adds a Vim keymap as a choice in Settings.

## Notes

- Copy mode moves through the scrollback of the pane. A full-screen program on the alternate screen (`less`, `btop`, an editor) has no scrollback. There, copy mode moves only on the visible screen.
- Copy mode starts at the terminal cursor, which is at the prompt. Press <kbd>k</kbd> or <kbd>⌃</kbd><kbd>u</kbd> to go up into the scrollback.
- In a multi-cell selection, the head is not drawn as a separate cursor yet. The selection is the cursor.
