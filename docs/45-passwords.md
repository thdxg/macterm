<!-- page:
slug: passwords
title: Password Manager
nav: Password Manager
group: Everyday use
description: Save the passwords that you type at terminal password prompts. Autofill them after Touch ID or your login password. This page says where Macterm stores them, how it matches them, and who can read them.
-->

# Password Manager

A program in a pane can ask for a password: `ssh`, `sudo`, `psql` or a key passphrase. Macterm notices this, and a bubble appears at the cursor. Macterm never saves a password unless you say so. Macterm never types a password for you unless you ask.

## Saving a password

Type the password as usual. When the password works (the login succeeds or the command runs), a bubble asks **Save Password?** The bubble shows the command and the password prompt. Press <kbd>Return</kbd> or click **Save** to save the password. Press <kbd>Esc</kbd> or click **Cancel** to forget it.

Macterm offers to save only a password that it saw work:

- Macterm never offers a password that the program rejected ("Permission denied", "Sorry, try again").
- Macterm never offers a one-time code. This includes verification codes, OTP, 2FA, authenticator prompts and token prompts.
- If Macterm cannot tell in 12 seconds whether the password worked, it offers nothing.
- If you run another command in the shell of the pane, the offer goes away. An offer that you do not answer expires after 15 minutes.

## Autofill

Sometimes the same command shows the same password prompt again. The bubble then offers **Autofill**. Do one of these: press <kbd>Return</kbd>, click the button, or press <kbd>⌥⌘F</kbd> (**Autofill Password** in Settings → Keymaps). Then confirm with Touch ID. On a Mac with no Touch ID, confirm with your login password. Macterm types the password and presses Return, as you would. Press <kbd>Esc</kbd> to put the bubble away. When you start to type, the keys are yours again.

Autofill happens only when you press the button. A program that shows a password prompt cannot make Macterm type. The bubble shows the command and the prompt line that the password is saved for. Read them before you press Return.

If a saved password stops working, the bubble says so. Type the new password. When it works, Macterm offers to update the saved password.

## Typing a password on demand

Macterm cannot see some password prompts. Examples: `sudo` on a server that you reached with `ssh`, and a prompt inside tmux. A password that you added yourself can also have no prompt. For these cases, open the command palette (<kbd>⌘P</kbd>) and select **Password Manager**. You can also go there with **View → Password Manager**, or with a keybind that you give to **Password Manager** in Settings → Keymaps. It has no keybind by default. If you press the keybind again, the palette closes. The palette shows your saved passwords. Type to search them by command or by prompt. Select one to type it into the focused pane. Press <kbd>Esc</kbd>, or press <kbd>Delete</kbd> with nothing typed, to go back to the full palette.

As with Autofill, Macterm types the password after Touch ID. Your selection is the permission. Nothing asks whether the pane is at a password prompt. Macterm only decides if it presses Return after the password:

- **At a password prompt that Macterm can see** (input by line, echo off), Macterm presses Return, as Autofill does.
- **At any other place**, Macterm types the password and leaves it for you. Examples: ssh or tmux that relays the prompt of a server, the prompt of your shell, or a line that shows what you type. Press <kbd>Return</kbd> to send the password. If it landed in the wrong place, clear it. Nothing ran. For `sudo` on a server, this is one extra Return.

## Adding a password yourself

Click **+** next to **Saved Passwords** in Settings → Password Manager. You can also select **Add Password…** in the Password Manager of the palette. While you search there, **Add Password for Command: …** starts a new password. It uses the text that you typed as the command. Each password that you add needs a command. The prompt is optional:

- **Command and prompt**: Macterm autofills the password when that command shows that prompt, as it does for a saved password.
- **Command only**: Macterm never offers the password at a prompt. It types the password only when you select it in the palette. Use this to keep, for example, the `sudo` password of a server.

Key passphrases are an exception. A passphrase belongs to the key, for any command that asks. Macterm saves it from the prompt. Type the passphrase at its prompt one time and save it there.

## What a password is saved for

Macterm files each password under two things: **the command that asked** and **the prompt line that it printed**. Both must match exactly before Macterm offers Autofill. Nothing else is part of the match. The project, the tab, the window and the working directory do not matter.

- **The command** is the real path of the program on disk, plus its arguments. Macterm reads them from the process table. `ssh prod` is filed as `/usr/bin/ssh prod`. A different program that calls itself `ssh` is a different command. An `ssh` from another place is also a different command.
- **The prompt line** is the last line that the program printed before it started to read. An example is `ethan@prod.example.com's password:`. This keeps the two passwords of `ssh -J bastion prod` apart: one command, two prompts.

Examples:

- **`ssh foo`, then `ssh bar`, from a shell.** These are two separate entries. Macterm offers each one when it works. You can save one, both or neither.
- **`ssh foo` in two different projects.** Passwords do not belong to a project. If both projects run the same command and see the same prompt, they share one entry.
- **Two machines that both have the name `foo`.** The prompt of ssh names the host that ssh really connects to. This is the `HostName` from your `~/.ssh/config`. It is not the alias that you typed. Aliases for different machines therefore get different entries. But the same name can reach two different machines, for example on a different network, with a different DNS or with a VPN. Then the command and the prompt are the same, and Macterm cannot tell them apart. It offers the same saved password on both machines. ssh checks the host key before it asks for a password. If a machine is not the one in your `known_hosts`, ssh gives its own warning first. If you use the same name for different machines, save the password for only one of them, or save none.
- **The own login of a remote project.** Macterm files it under `ssh user@host` from the path of the project. Two remote projects on the same host share it.

There are two exceptions to the command rule:

- **`sudo`** has one entry for every `sudo …` command. It is always your login password.
- **Key passphrases** (`Enter passphrase for key '…'`) belong to the key, for any command that asks (`ssh`, `ssh-add`, `git`).

Macterm offers these two shared entries only to a program that your own account cannot change or replace. The file of the program, and every folder above it, belongs to the system (`/usr/bin/sudo`, `/usr/bin/ssh`). Macterm keeps every other program apart. A program with the name `sudo` in `~/bin` or `/opt/homebrew/bin` gets its own entries. The bubble shows its full path. Then it cannot get your login password as if it were the real `sudo`. When a program outside the system folders asks for a passphrase (Homebrew's `ssh`, for example), Macterm saves the passphrase for that program only.

If Macterm cannot tell which program asks, it offers no Autofill and no save for that prompt.

**Details…** in Settings → Password Manager shows the exact command and the prompt that an entry matches. You can edit them. If you clear the prompt, the entry is only for the palette. You cannot clear the command. An entry for a prompt from any command (a key passphrase) stays that way.

## Where passwords are stored

Macterm stores passwords in your **login keychain** (`~/Library/Keychains/login.keychain-db`). This is the file-based keychain where most Mac apps keep their passwords. Each password is one generic-password item:

| Keychain Access field | Value |
| --- | --- |
| **Name** | `Macterm: <command>` |
| **Kind** | Macterm terminal password |
| **Where** (service) | `com.thdxg.macterm.passwords` |
| **Account** | The command and the prompt that it matches |

You can see the items in **Keychain Access** (login keychain → Passwords, search "Macterm"). Macterm does **not** sync them to iCloud Keychain or to your other Macs. If you remove Macterm, the items stay. Remove them first in Settings → Password Manager, or in Keychain Access.

Your login password locks the login keychain. It unlocks when you log in. The access list of each item trusts only the code signature of Macterm. Any other app, and the `security` command, shows the system dialog "wants to use your confidential information" when it asks to read an item. That dialog needs your login password.

## Who can read them

- **Macterm, after you authenticate.** Macterm asks for Touch ID before it reads a saved password. On a Mac with no Touch ID, it asks for your login password. This applies to autofill, and to **Show**, **Copy** and **Change** in Settings. **Require authentication** has the default **Once per app launch**. One approval then covers every read until Macterm quits, the Mac locks or sleeps, or you switch users. Macterm never saves the approval to disk. Set **Require authentication** to **Every time** to authenticate at each use.
- **Not the `macterm` CLI, Shortcuts, or any program in a pane.** No command, no intent and no socket request returns a saved password. Macterm never prints a password to a pane. (Autofill types it, in the same way as a key press.) Macterm never writes a password to its logs.

Macterm is the terminal, so every key that you type already passes through it. At a password prompt, Macterm keeps a copy of the line in memory. It uses the copy to judge if the password worked. Macterm drops the copy when the verdict arrives, after 12 seconds at most. An exception is a save offer. The copy then stays in memory until you answer the offer, run another command, or 15 minutes pass. Macterm never writes the copy to disk unless you click **Save**.

While a pane is at a password prompt, Macterm also turns on macOS **Secure Keyboard Entry**. Other apps then cannot read the keys that you type there. This follows the ghostty key `macos-auto-secure-input` (on by default).

## Touch ID and your other setups

Macterm does not change any system authentication setting. Its authentication request is the standard macOS request ("Macterm is trying to autofill the password for …"). Macterm itself asks for it. Macterm does not touch PAM, the configuration of `sudo`, your ssh agent or the settings of your keychain.

- **Touch ID for `sudo`** (`pam_tid` in `/etc/pam.d/sudo_local`) keeps working. sudo asks for your fingerprint first. Macterm sees a password prompt only if sudo falls back to a password at the terminal. This happens, for example, after you cancel the fingerprint dialog.
- **ssh agents and password managers** (1Password, Secretive, `ssh-add --apple-use-keychain`) keep working. They answer ssh with no password prompt at the terminal, so Macterm never sees a prompt.

## Settings → Password Manager

| Setting | What it does |
| --- | --- |
| **Enable password manager** | On (the default): Macterm offers to save passwords and offers autofill. Off: Macterm does not save, capture or fill in anything. The **Password Manager** of the palette is also off. The setting below is disabled. |
| **Require authentication** | **Once per app launch** (the default) or **Every time**. With **Once per app launch**, Macterm also asks again after the Mac locks or sleeps. |
| **Saved Passwords** | Search the list. **+** adds a password. The menu of a row has **Details…**, **Copy Password** and **Remove**. **Details…** shows the full command and prompt, which you can edit. After you authenticate, it shows the password, which you can copy or change. |

To turn the feature off, switch off **Enable password manager**. Macterm then never keeps a copy of what you type at a password prompt, never shows a bubble and never fills in anything. The passwords that you already saved stay in your keychain until you remove them. The list stays available for that. Macterm still notices password prompts, because that also turns on Secure Keyboard Entry.

## Limits

Macterm detects a password prompt by the terminal mode in which the program reads it (input by line, echo off). Ghostty and iTerm2 use the same rule for secure input. This covers local panes and the own ssh login of a remote project. It does not cover a prompt on a remote host inside an ssh session, for example `sudo` on a server. It also does not cover prompts that draw their own `*` characters. For these, [type the password on demand](#typing-a-password-on-demand).
