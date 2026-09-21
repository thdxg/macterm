<!-- page:
slug: remote-projects
title: Remote projects
nav: Remote projects
group: Projects & sessions
description: Projects that live on a remote machine over SSH, with panes that persist on the host — surviving quits, disconnects, and even local reboots.
-->

# Remote projects

A project whose directory lives on another machine. Every pane is a persistent [zmx](https://zmx.sh) session running **on that host** over SSH, so shells, processes, and scrollback survive quitting Macterm, a dropped connection, and rebooting your Mac.

## Requirements

**SSH access to the host.** Authentication happens interactively in the pane, so anything that works for `ssh` works here.

**zmx installed on the host**, somewhere on your `PATH`. `~/bin` and `~/.local/bin` are found even when your profile isn't loaded.

```sh title="on the remote host"
curl -fsSL https://zmx.sh/a/zmx-0.6.0-linux-x86_64.tar.gz | tar xz -C ~/bin
```

Use `linux-aarch64` for ARM hosts.

**Connection settings come from `~/.ssh/config`**, never from Macterm. Define a `Host` alias and use the alias as the project's host.

```text title="~/.ssh/config"
Host devbox
  HostName dev.example.com
  User deploy
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
  # makes new tabs and splits connect near-instantly:
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
```

## Creating one

**Sidebar → + → Remote Machine…**

| Field | Value |
| --- | --- |
| **Host** | `devbox`, `user@host`, or any ssh-config alias |
| **Directory** | `~/dev/api`, `/srv/app`, or a path relative to the remote home |
| **zmx path** *(optional)* | Absolute path to zmx on the host. Leave blank to auto-detect. |

Or type `devbox:~/dev/api` into the command palette (<kbd>⌘P</kbd>) and pick **Add remote project**.

## How panes behave

| Action | Effect |
|---|---|
| New tab / split | New zmx session on the host, starting in the project directory |
| Quit Macterm | Sessions detach and keep running on the host |
| Relaunch | Every pane reattaches, scrollback and processes intact |
| Close a pane or tab | Its session on the host is killed (you're asked first if something is running) |
| Local reboot / network drop | Sessions keep running; dropped panes reconnect automatically |

Reconnection happens when the Mac wakes, when you return to the app, or when you select the project. Turn it off with **Settings → General → Remote Projects → Reconnect panes after a dropped connection**.

## Layouts

[Declarative layouts](/docs/declarative-layouts) work unchanged. Per-pane `cwd` and `~` resolve on the remote side.

```yaml title="~/.config/macterm/projects/api.yaml"
name: "API (devbox)"
path: "devbox:~/dev/api"
zmxPath: "~/bin/zmx"   # only if auto-detection fails
tabs:
  - run: "npm run dev"
  - name: "Logs"
    cwd: "logs"
```

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `macterm: zmx not found in PATH on this host` | Move zmx to `~/bin` or `~/.local/bin`, or set the project's **zmx path** to its absolute location. |
| `macterm: cannot cd to …` | The directory doesn't exist on the host. The pane drops to a shell in your home directory. |
| Slow tab/split opening | Add `ControlMaster` to your ssh config (example above). |
| Touch ID prompts repeatedly | Add `ControlMaster`, so background polls reuse the pane's authenticated connection. Cancelling once also stops polling that host until you open a new pane on it. |
| Any background prompt at all | Turn off **Settings → General → Remote Projects → Background SSH connections**. You lose live tab naming, remote `run:` capture in Save Layout, orphan cleanup, and busy-close warnings without [shell integration](https://ghostty.org/docs/features/shell-integration) on the host. |

## Limitations

- zmx must be preinstalled on the host — no upload flow yet.
- Orphan cleanup only touches sessions this installation marked as its own, so a session orphaned before it was marked needs `zmx ls` / `zmx kill` by hand.
- **Replace Project Path with Current Dir** and other local-directory features are disabled.
