<!-- page:
slug: passwords
title: Password Manager
nav: Password Manager
group: Everyday use
description: Save the passwords you type at terminal prompts and autofill them after Touch ID or your login password — where they're stored, what they're matched by, and who can read them.
-->

# Password Manager

When a program in a pane asks for a password — `ssh`, `sudo`, `psql`, a key passphrase — Macterm notices, and a bubble appears at the cursor. Nothing is ever saved without you saying so, and nothing is ever typed for you without you asking.

## Saving a password

Type the password as usual. Once it works (the login goes through, the command runs), a bubble asks **Save Password?** with the command and the prompt it's for. Press <kbd>Return</kbd> or click **Save**; press <kbd>Esc</kbd> or click **Cancel** to forget it.

Macterm offers only a password it has seen work:

- A password the program rejected ("Permission denied", "Sorry, try again") is never offered.
- One-time codes (verification codes, OTP, 2FA, authenticator or token prompts) are never offered.
- If Macterm can't tell whether the password worked within 12 seconds, nothing is offered.
- Running another command in the pane's shell dismisses the offer. An unanswered offer expires after 15 minutes.

## Autofill

The next time the same command shows the same prompt, the bubble offers **Autofill**. Press <kbd>Return</kbd>, click it, or press <kbd>⌥⌘F</kbd> (**Autofill Password** in Settings → Keymaps), and confirm with Touch ID — or your login password, on a Mac without Touch ID. Macterm types the password and presses Return, exactly as if you had. <kbd>Esc</kbd> puts the bubble away; start typing and the keys are yours again.

Autofill only ever happens when you press it — a program showing a prompt can't make Macterm type anything. The bubble shows the command and prompt line the password is saved for; check them before you press Return.

If a saved password stops working, the bubble says so. Type the new one, and Macterm offers to update the saved password once it works.

## Typing a password on demand

Some prompts Macterm can't see — `sudo` on a server you reached with `ssh`, or a prompt inside tmux — and a password you added yourself may not belong to any prompt at all. For those, open the command palette (<kbd>⌘P</kbd>) and choose **Password Manager** — or go straight there from **View → Password Manager**, or a shortcut you give **Password Manager** in Settings → Keymaps (none by default; pressing it again closes the palette). The palette switches to your saved passwords; type to search them by command or prompt, and pick one to type it into the focused pane. <kbd>Esc</kbd>, or <kbd>Delete</kbd> with nothing typed, goes back to the full palette.

After Touch ID, as for Autofill, Macterm types the password. Picking it is the go-ahead: nothing asks whether the pane is really at a password prompt. What Macterm decides is whether to press Return after it:

- **At a password prompt it can see** (input by line, echo off), Return is pressed, as Autofill would.
- **Anywhere else** — ssh or tmux relaying a server's prompt, your shell's own prompt, a line that shows what you type — the password is typed and left for you: press <kbd>Return</kbd> to send it. If it landed in the wrong place, delete it instead; nothing has run. For `sudo` on a server, that's one extra Return.

## Adding a password yourself

Click **+** next to **Saved Passwords** in Settings → Password Manager, or choose **Add Password…** in the palette's Password Manager. While searching there, **Add Password for Command: …** starts one with what you typed as the command. Every password you add needs a command; the prompt is up to you:

- **Command and prompt**: autofilled when that command shows that prompt, exactly like a saved one.
- **Command only**: never offered at a prompt. It's typed only when you pick it from the palette — the way to keep, say, a server's `sudo` password.

Key passphrases are the exception: they belong to the key, whichever command asks, so they're saved from the prompt itself. Type one at its prompt once and save it there.

## What a password is saved for

Each password is filed under two things: **the command that asked** and **the prompt line it printed**. Both must match exactly for Autofill to be offered. Nothing else is part of the match — not the project, the tab, the window, or the working directory.

- **The command** is the program's real path on disk plus its arguments, read from the process table: `ssh prod` is filed as `/usr/bin/ssh prod`. A different program that calls itself `ssh`, or an `ssh` from somewhere else, is a different command.
- **The prompt line** is the last line the program printed before it started reading, such as `ethan@prod.example.com's password:`. This is what keeps `ssh -J bastion prod`'s two passwords apart: one command, two prompts.

A few examples:

- **`ssh foo`, then `ssh bar`, from a shell.** Two separate entries, and each is offered separately once it works. You can save either, both, or neither.
- **`ssh foo` in two different projects.** Passwords aren't per project, so if both projects run the same command and see the same prompt, they share one entry.
- **Two machines both called `foo`.** ssh's prompt names the host it actually connects to — the `HostName` from your `~/.ssh/config`, not the alias you typed — so aliases that point at different machines get different entries. But if the same name really reaches two different machines (a different network, DNS or VPN), the command and prompt are identical and Macterm can't tell them apart: it offers the same saved password on both. ssh checks the host key before it asks for a password, so a machine that isn't the one in your `known_hosts` gets ssh's own warning first. If you use the same name for different machines, save only one of them, or don't save.
- **A remote project's own login** is filed under `ssh user@host` from the project's path, so two remote projects on the same host share it.

Two exceptions to the command rule:

- **`sudo`** keeps one entry for every `sudo …` command — it's always your login password.
- **Key passphrases** (`Enter passphrase for key '…'`) belong to the key, whichever command asks (`ssh`, `ssh-add`, `git`).

These two shared entries are only offered to a program your own account can't have put there or changed: one whose file, and every folder above it, belongs to the system (`/usr/bin/sudo`, `/usr/bin/ssh`). Anything else is kept apart. A program named `sudo` in `~/bin` or `/opt/homebrew/bin` gets entries of its own, and the bubble shows its full path, so it can't be offered your login password as if it were the real `sudo`. A passphrase asked by a program outside the system folders (Homebrew's `ssh`, for example) is saved for that program alone.

If Macterm can't tell which program is asking, it doesn't offer Autofill or a save for that prompt.

**Details…** in Settings → Password Manager shows the exact command and prompt an entry matches, and lets you edit them. Clearing the prompt makes it a palette-only entry. The command can't be cleared; an entry saved for a prompt from any command (a key passphrase) stays that way.

## Where passwords are stored

In your **login keychain** (`~/Library/Keychains/login.keychain-db`), the file-based keychain most Mac apps keep their passwords in. Each password is one generic-password item:

| Keychain Access field | Value |
| --- | --- |
| **Name** | `Macterm: <command>` |
| **Kind** | Macterm terminal password |
| **Where** (service) | `com.thdxg.macterm.passwords` |
| **Account** | the command and prompt it matches |

You can see them in **Keychain Access** (login keychain → Passwords, search "Macterm"). They are **not** synced to iCloud Keychain or to your other Macs. Removing Macterm doesn't remove them; remove them in Settings → Password Manager first, or delete them in Keychain Access.

The login keychain is locked with your login password and unlocks when you log in. Each item's access list trusts only Macterm's code signature, so any other app — or the `security` command — asking to read one gets the system's "wants to use your confidential information" dialog, which needs your login password.

## Who can read them

- **Macterm, after you authenticate.** Every read of a saved password — autofill, and **Show**, **Copy** or **Change** in Settings — asks for Touch ID (or your login password, on a Mac without it) first. With **Require authentication** set to **Once per app launch** (the default), one approval covers every read until Macterm quits, the Mac locks or sleeps, or you switch users; the approval is never saved to disk. Set it to **Every time** to be asked on each use.
- **Not the `macterm` CLI, Shortcuts, or any program in a pane.** There is no command, intent or socket request that returns a saved password. Macterm never prints a password to a pane (autofill types it, the same as a keystroke), and never writes one to its logs.

Macterm is the terminal, so every key you type passes through it already. At a password prompt, it keeps a copy of the line in memory to judge whether the password worked. That copy is dropped as soon as the verdict comes in (at most 12 seconds), unless it becomes a save offer — which stays in memory only until you answer it, run another command, or 15 minutes pass. It is never written to disk unless you click **Save**.

While a pane is at a password prompt, Macterm also turns on macOS **Secure Keyboard Entry**, so other apps can't read the keys you type there. This follows ghostty's `macos-auto-secure-input` key (on by default).

## Touch ID and your other setups

Macterm doesn't change any system authentication settings. Its authentication prompt is the standard macOS one ("Macterm is trying to autofill the password for …"), asked for by Macterm itself; it doesn't touch PAM, `sudo`'s configuration, your ssh agent, or your keychain's settings.

- **Touch ID for `sudo`** (`pam_tid` in `/etc/pam.d/sudo_local`) keeps working. sudo asks for your fingerprint first; Macterm only sees a prompt if sudo falls back to reading a password at the terminal — after you cancel the fingerprint dialog, for example.
- **ssh agents and password managers** (1Password, Secretive, `ssh-add --apple-use-keychain`) keep working. They answer ssh without a terminal prompt, so Macterm never sees one.

## Settings → Password Manager

| Setting | What it does |
| --- | --- |
| **Enable password manager** | On (the default): offer to save, and autofill. Off: nothing is saved, captured or filled in — the palette's **Password Manager** included — and the setting below is disabled. |
| **Require authentication** | **Once per app launch** (the default; also asks again after the Mac locks or sleeps), or **Every time**. |
| **Saved Passwords** | Search the list; **+** adds a password; a row's menu offers **Details…** (the full command and prompt, editable, and the password after you authenticate — shown, copied or changed), **Copy Password** and **Remove**. |

To turn the feature off, switch off **Enable password manager**. Macterm then never keeps a copy of what you type at a prompt, never shows a bubble and never fills anything in. Passwords you already saved stay in your keychain until you remove them, and the list stays available for that. Macterm still notices password prompts, because that is also what turns on Secure Keyboard Entry.

## Limits

Macterm detects a prompt by the terminal mode the program reads it in (input by line, echo off) — the same rule Ghostty and iTerm2 use for secure input. That covers local panes and a remote project's own ssh login, but not a prompt on a remote host inside an ssh session — for example `sudo` on a server — nor prompts that draw their own `*` characters. For those, [type the password on demand](#typing-a-password-on-demand).
