<!-- page:
slug: remote-projects
title: Remote projects
nav: Remote projects
group: Projects & sessions
description: Projects on a remote machine over SSH. The panes keep running on the host when you quit, when the connection drops and when you restart your Mac.
-->

# Remote projects

A remote project is a project whose folder is on another machine. Each pane is a session of Macterm's server, which runs **on that host**. All panes of a host use one SSH connection, so you log in one time for each host. Your shells, processes and scrollback keep running when you quit Macterm, when the connection drops and when you restart your Mac.

## Requirements

**SSH access to the host.** Anything that works for `ssh` works here. When the login asks for a password, a passphrase or a new host key, Macterm asks you in a sheet.

**Linux (x86_64 or aarch64) or macOS on the host.** At the first connection to a host, Macterm asks to install its server there, in `~/.local/share/macterm`. The server comes from Macterm, not from the internet of the host, and the host checks its checksum. Later versions install with no question.

If you choose **Continue Without Server**, each pane is a plain SSH shell. It ends when the connection stops, and its tab shows no program name. To install the server later, open the menu of the project in **Settings → Projects** and choose **Install Server on Host…**. A host with no build (for example, BSD) also gets plain shells.

**Windows hosts are not supported.** When the SSH shell of the host is `cmd.exe` or PowerShell, the pane says that the host runs Windows and that Macterm does not support it.

**Connection settings come from `~/.ssh/config`.** They never come from Macterm. Define a `Host` alias and use the alias as the host of the project. When your config has a `ControlMaster` that is running, Macterm uses it and logs in to nothing.

```text title="~/.ssh/config"
Host devbox
  HostName dev.example.com
  User deploy
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
```

## Creating one

Go to **Sidebar → + → Remote Machine…**

| Field | Value |
| --- | --- |
| **Host** | `devbox`, `user@host` or any alias from your ssh config |
| **Directory** | `~/dev/api`, `/srv/app`, or a path that is relative to the remote home |

You can also type `devbox:~/dev/api` in the command palette (<kbd>⌘P</kbd>) and select **Add remote project**.

## How panes behave

| Action | Effect |
|---|---|
| New tab or split | A new session starts on the host, in the project directory. |
| Quit Macterm | The sessions keep running on the host. |
| Start Macterm again | Every pane connects to its session again, with its scrollback and processes. |
| Close a pane or tab | Its session on the host ends. Macterm asks you first if a program is running. |
| The shell in a pane exits | The pane closes. |
| Restart your Mac, or the network drops | The sessions keep running. The panes that lost the connection connect again. |
| The host restarts | The sessions on the host end. Each pane says so. Press Return to start a new shell in the same folder. |

A pane that lost its connection keeps its last screen, blurred and dimmed. Macterm connects it again when the Mac wakes, when the network changes, when you return to the app, when you select the project, and when you log in to its host from another pane. Press a key in the pane to connect at once. To connect only when you press a key, turn off **Settings → General → Remote Projects → Reconnect panes after a dropped connection**.

When a connection fails, the pane says why, for example `No host is named devbox.` or `devbox does not answer.` Press a key to try again.

### Tab names and busy panes

Macterm names a remote tab after the program that runs in it, shows the logo of a coding agent, and asks before it closes a pane whose program still runs. The server on the host tells the pane about each change of its foreground process, through the connection of the pane itself. The name follows the host at once.

## Layouts

[Declarative layouts](/docs/declarative-layouts) work with no change. The `cwd` of each pane and `~` resolve on the remote side.

```yaml title="~/.config/macterm/projects/api.yaml"
name: "API (devbox)"
path: "devbox:~/dev/api"
tabs:
  - run: "npm run dev"
  - name: "Logs"
    cwd: "logs"
```

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `macterm: cannot cd to …` | The directory does not exist on the host. The session starts in your home directory. |
| An agent shows its logo but never its busy or done dot | The session of the tab started before Macterm began to tell the host that it runs in Ghostty. Agents need this before they report progress. Open a new tab or pane for the agent. |

## Sessions from Macterm 1

Macterm 1 ran a zmx session on the host for each pane. Macterm 2 does not use them: at the first start, each remote pane starts a new session in the project directory. The old sessions keep running on the host. To see and end them, run `zmx ls` and `zmx kill` on the host.

## Limitations

- A session whose pane you close while the host is not connected stays on the host.
- **Replace Project Path with Current Dir** and other local-directory features are off.
- A session keeps the environment from the time when Macterm created it. After you upgrade Macterm, an existing remote tab does not get new variables (for example, the variable that lets agents report progress). Open a new tab or pane instead.
