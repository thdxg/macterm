<!-- page:
slug: remote-projects
title: Remote projects
nav: Remote projects
group: Projects & sessions
description: Projects on a remote machine over SSH. The panes keep running on the host when you quit, when the connection drops and when you restart your Mac.
-->

# Remote projects

A remote project is a project whose folder is on another machine. Each pane is a persistent [zmx](https://zmx.sh) session that runs **on that host** over SSH. Your shells, processes and scrollback keep running when you quit Macterm, when the connection drops and when you restart your Mac.

## Requirements

**SSH access to the host.** You sign in interactively in the pane. Anything that works for `ssh` works here.

**zmx 0.7.1 or later on the host**, in a folder in your `PATH`. Macterm finds `~/bin` and `~/.local/bin` also when the host does not load your profile. Macterm uses the session labels of zmx to find and remove orphan sessions. Labels start in zmx 0.7.0. Version 0.7.1 also fixes a hang with sessions that zmx 0.6.0 started.

The simple way is **Install zmx on Host…** in Macterm, which puts Macterm's own build there (see "Installing zmx on the host" below). To install the upstream zmx by hand instead:

```sh title="on the remote host"
curl -fsSL https://zmx.sh/a/zmx-0.8.1-linux-x86_64.tar.gz | tar xz -C ~/bin
```

For ARM hosts, use `linux-aarch64`. To see the version on the host, run `zmx version`.

**Connection settings come from `~/.ssh/config`.** They never come from Macterm. Define a `Host` alias and use the alias as the host of the project.

```text title="~/.ssh/config"
Host devbox
  HostName dev.example.com
  User deploy
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
  # makes new tabs and splits connect almost at once:
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
```

## Creating one

Go to **Sidebar → + → Remote Machine…**

| Field | Value |
| --- | --- |
| **Host** | `devbox`, `user@host` or any alias from your ssh config |
| **Directory** | `~/dev/api`, `/srv/app`, or a path that is relative to the remote home |
| **zmx path** *(optional)* | The absolute path to zmx on the host. Leave it empty to let Macterm find it. |

You can also type `devbox:~/dev/api` in the command palette (<kbd>⌘P</kbd>) and select **Add remote project**.

## How panes behave

| Action | Effect |
|---|---|
| New tab or split | A new zmx session starts on the host, in the project directory. |
| Quit Macterm | The sessions disconnect and keep running on the host. |
| Start Macterm again | Every pane connects to its session again, with its scrollback and processes. |
| Close a pane or tab | Its session on the host ends. Macterm asks you first if a program is running. |
| Restart your Mac, or the network drops | The sessions keep running. The panes that lost the connection connect again by themselves. |

Macterm connects a pane again when the Mac wakes, when you return to the app, and when you select the project. To turn this off, use **Settings → General → Remote Projects → Reconnect panes after a dropped connection**.

A pane that lost its connection shows `Process exited. Press any key to close the terminal.` Press a key to close the pane. This is the same as **Close Pane**: Macterm asks you first if a program is running in the session.

### Tab names and busy panes

Macterm names a remote tab after the program that runs in it, shows the logo of a coding agent, and asks before it closes a pane whose program still runs. How it learns what runs depends on the zmx on the host:

- With [Macterm's zmx build](https://github.com/thdxg/zmx/releases) on the host, the session tells the pane about each change of its foreground process, through the connection of the pane itself. The name follows the host at once, and it works with **Background SSH connections** off.
- With the upstream zmx, Macterm asks the host over a separate ssh connection about every 3 seconds. The name can be a few seconds late, and the questions stop when you turn **Background SSH connections** off.

## Layouts

[Declarative layouts](/docs/declarative-layouts) work with no change. The `cwd` of each pane and `~` resolve on the remote side.

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
| `macterm: zmx not found in PATH on this host` | Move zmx to `~/bin` or `~/.local/bin`. Or set the **zmx path** of the project to the absolute location. |
| `macterm: cannot cd to …` | The directory does not exist on the host. The pane starts a shell in your home directory. |
| Tabs or splits open slowly | Add `ControlMaster` to your ssh config (see the example above). |
| Touch ID asks again and again | Add `ControlMaster`. Then background polls use the authenticated connection of the pane. If you cancel one time, Macterm stops polling that host. It starts again when you open a new pane on that host. |
| An agent shows its logo but never its busy or done dot | The session of the tab started before Macterm began to tell the host that it runs in Ghostty. Agents need this before they report progress. Open a new tab or pane for the agent. |
| Any background prompt at all | Turn off **Settings → General → Remote Projects → Background SSH connections**. You lose remote `run:` capture in Save Layout and cleanup of orphan sessions. On a host with the upstream zmx, you also lose live tab names and agent logos, and, with no [shell integration](https://ghostty.org/docs/features/shell-integration), busy-close warnings. A host with Macterm's zmx build keeps all three (see "Tab names and busy panes"). |

## Installing zmx on the host

Macterm can put its own zmx build on the host. In **Settings → Projects**, open the menu of a remote project and choose **Install zmx on Host…**. The same button is in the **New Remote Project** sheet, so you can install before you add the project.

The sheet asks the host what it is (Linux x86_64, Linux aarch64 or macOS) and which zmx it runs, and tells you what it will do. Nothing on the host changes until you click **Install** or **Update**. If the host asks for a password, a passphrase or a host key, the sheet asks you. The binary comes from Macterm, not from the internet of the host, and Macterm checks its checksum first. It goes to `~/.local/bin/zmx`, which the panes of Macterm find. When the host already has another zmx first in its PATH, Macterm sets the **zmx path** of the project to the new one.

A session that is running keeps its old zmx until you close and open it again. Macterm's build has fixes that its remote panes rely on, for example the foreground reports (see "Tab names and busy panes"). Choose **Install zmx on Host…** again after a Macterm update to get the build that it pins.

## Limitations

- Orphan cleanup only touches sessions that this installation marked as its own. A zmx older than 0.7.0 cannot keep the mark. On such a host, Macterm removes no orphan sessions. After you upgrade zmx, the sessions that the old zmx started still have no mark. For these sessions, and for a session that became an orphan before the mark, run `zmx ls` and `zmx kill` by hand.
- **Replace Project Path with Current Dir** and other local-directory features are off.
- A session keeps the environment from the time when Macterm created it. After you upgrade Macterm, an existing remote tab does not get new variables (for example, the variable that lets agents report progress). Open a new tab or pane instead.
