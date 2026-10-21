<!-- page:
slug: copy-mode
title: Copy Mode
nav: Copy Mode
group: Everyday use
description: Move through the scrollback and select text with the keyboard, with the keys of Helix. This page lists the keys and says how to change the keybind.
-->

# Copy Mode

Copy mode lets you move through the scrollback and select text with the keyboard. It is the copy mode of tmux and the vi mode of Alacritty, with the keys of Helix.

Press <kbd>⌘</kbd><kbd>⇧</kbd><kbd>Space</kbd> in a pane to start it. The cursor becomes a block that you move, and a **Copy Mode** pill appears in the corner of the pane. A click on the pill also leaves the mode. Press <kbd>Esc</kbd> to leave it. The cursor goes back to where the shell left it, and the pane types into the shell again.

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

## Vim keys

Go to **Settings → Keymaps → Copy Mode** and select **Vim**. The change applies the next time copy mode starts. With Vim keys, copy mode works as the vi copy mode of tmux:

| Key | Motion |
|---|---|
| <kbd>h</kbd> <kbd>j</kbd> <kbd>k</kbd> <kbd>l</kbd>, arrows | One cell left or right, one row up or down |
| <kbd>w</kbd> <kbd>e</kbd> <kbd>b</kbd> | The start of the next word, the end of the word, the start of the word |
| <kbd>0</kbd> <kbd>^</kbd> <kbd>$</kbd>, <kbd>Home</kbd> <kbd>End</kbd> | The start of the row, the last character of the row |
| <kbd>g</kbd><kbd>g</kbd> <kbd>G</kbd> | The top of the scrollback, the last character on the screen |
| <kbd>⌃</kbd><kbd>u</kbd> <kbd>⌃</kbd><kbd>d</kbd> <kbd>⌃</kbd><kbd>b</kbd> <kbd>⌃</kbd><kbd>f</kbd>, <kbd>Page Up</kbd> <kbd>Page Down</kbd> | Half a screen, a screen |

A number before a motion repeats it.

| Key | Selection |
|---|---|
| <kbd>v</kbd> | Start or stop visual mode. The pill says **Visual** |
| <kbd>V</kbd> | Visual line mode: whole lines. The pill says **Visual Line** |
| <kbd>⌃</kbd><kbd>v</kbd> | Visual block mode: a rectangle. The pill says **Visual Block** |
| <kbd>o</kbd> | Swap the two ends of the selection |
| <kbd>y</kbd> | In visual mode: copy the selection and leave copy mode |
| <kbd>y</kbd><kbd>y</kbd> <kbd>Y</kbd> | Copy the line of the cursor and leave copy mode |
| <kbd>/</kbd> <kbd>n</kbd> <kbd>N</kbd> | Search, the next match, the previous match |
| <kbd>Esc</kbd> | Leave visual mode, then leave copy mode |
| <kbd>q</kbd> | Leave copy mode |

The mouse still works. A drag makes a selection, and the next motion continues from it.

## The keybind

**Copy Mode** is a row in Settings → Keymaps. Change its keys there. It is also in the command palette and in the View menu.

The keys inside copy mode are the Helix keys or the Vim keys (**Settings → Keymaps → Copy Mode**). You cannot change single keys.

## Notes

- Copy mode moves through the scrollback of the pane. A full-screen program on the alternate screen (`less`, `btop`, an editor) has no scrollback. There, copy mode moves only on the visible screen.
- Copy mode starts at the terminal cursor, which is at the prompt. Press <kbd>k</kbd> or <kbd>⌃</kbd><kbd>u</kbd> to go up into the scrollback.
- The cursor of copy mode is the cursor of the pane, drawn on the head of the selection. The shell's own cursor does not move, and comes back when you leave the mode. With **Smooth cursor** on (Settings → Animations), the cursor glides between motions.
