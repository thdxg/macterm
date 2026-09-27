<!-- page:
slug: passwords
title: Passwords
nav: Passwords
group: Everyday use
description: Save the passwords you type at terminal prompts and autofill them with Touch ID.
-->

# Passwords

When a program in a pane asks for a password — `ssh`, `sudo`, `psql`, a key passphrase — Macterm notices, and a bubble appears at the cursor.

## Saving a password

Type the password as usual. Once it works (the login goes through, the command runs), a bubble asks **Save Password?** with the command and the prompt it's for. Press <kbd>Return</kbd> or click **Save**; press <kbd>Esc</kbd> or click **Cancel** to forget it. A password that was rejected is never offered, one-time codes are never offered, and running another command in the pane dismisses the offer.

## Autofill

The next time the same command shows the same prompt, the bubble offers **Autofill**. Press <kbd>Return</kbd>, click it, or press <kbd>⌥⌘F</kbd> (**Autofill Password** in Settings → Keymaps), and confirm with Touch ID or your login password. Macterm types the password and presses Return, exactly as if you had. <kbd>Esc</kbd> puts the bubble away; start typing and the keys are yours again.

If a saved password stops working, the bubble says so. Type the new one, and Macterm offers to update the saved password once it works.

## What a password is saved for

Each password is filed under the command that asked for it plus the prompt line it printed, so `ssh -J bastion prod` can keep the bastion's password and prod's separately. Two exceptions:

- **`sudo`** keeps one entry for every `sudo …` command — it's always your login password.
- **Key passphrases** (`Enter passphrase for key '…'`) belong to the key, whichever command asks.

## Settings → Passwords

| Setting | What it does |
| --- | --- |
| **Offer to save passwords** | Off stops the save offer. Saved passwords still autofill. |
| **Require Touch ID to autofill** | **Every time**, or **Once until the Mac locks** (also relocks on sleep and quit). |
| **Saved Passwords** | Search, copy (after Touch ID) or remove any saved password. |

Passwords are stored in your login keychain. Macterm never prints them, logs them, or exposes them to the `macterm` CLI or Shortcuts.

## Limits

Macterm detects a prompt by the terminal mode the program reads it in (input by line, echo off). That covers local panes and a remote project's own ssh login, but not a prompt on a remote host inside an ssh session — for example `sudo` on a server — nor prompts that draw their own `*` characters.
