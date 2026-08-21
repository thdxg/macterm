<!-- page:
slug: remote-projects
title: Remote projects
nav: Remote projects
group: Projects & sessions
description: Projects that live on a remote machine over SSH, with panes that persist on the host — surviving quits, disconnects, and even local reboots.
-->

# Remote projects

A remote project is a directory on another machine. Every pane in it is a persistent [zmx](https://zmx.sh) session running **on that host** over SSH — so your shells, running processes, and scrollback live on the server, not on your Mac. Quit Macterm and the sessions keep running; relaunch and every pane reattaches. Because the host's session daemon outlives your laptop, remote panes even survive a local reboot or a dropped connection — reconnecting is just reattaching.

## Requirements

- **SSH access to the host.** Password, key, or 2FA — authentication happens interactively inside the pane, so anything that works for `ssh` in a terminal works here.
- **zmx installed on the host.** Grab a prebuilt binary and put it somewhere on your `PATH` — `~/bin` and `~/.local/bin` are found even when your profile isn't loaded:

```sh title="on the remote host"
curl -fsSL https://zmx.sh/a/zmx-0.6.0-linux-x86_64.tar.gz | tar xz -C ~/bin
```

(Pick the tarball matching the host's architecture — `linux-aarch64` for ARM machines.)

Port, identity file, and other connection settings come from your `~/.ssh/config`, never from Macterm — define a `Host` alias there and use the alias as the project's host:

```text title="~/.ssh/config"
Host devbox
  HostName dev.example.com
  User deploy
  Port 2222
  IdentityFile ~/.ssh/id_ed25519
  # optional, but makes new tabs and splits connect near-instantly:
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
```

## Creating a remote project

**Sidebar → + → Remote Machine…** and fill in:

- **Host** — `devbox`, `user@host`, or any ssh-config alias.
- **Directory** — where the project lives on the host: `~/dev/api`, `/srv/app`, or a path relative to the remote home.
- **zmx path** *(optional)* — an absolute path to zmx on the host, used verbatim. Leave blank to auto-detect; set it if the pane reports `zmx not found` (see [troubleshooting](#troubleshooting)).

Or skip the sheet: type `devbox:~/dev/api` into the command palette (<kbd>⌘P</kbd>) — the same path mode that recognizes local directories recognizes remote specs and offers **Add remote project**.

Remote projects show a small network badge in the sidebar. The first connection may ask you to confirm the host key — answer right in the pane, like any ssh session.

## How panes behave

| Action | Effect |
|---|---|
| New tab / split | New zmx session on the host, shell starts in the project directory |
| Quit Macterm | SSH disconnects; sessions **detach and keep running** on the host |
| Relaunch | Every pane reattaches — scrollback and running processes intact |
| Close a pane or tab | Its session on the host is killed (you're asked first if something is running) |
| Local reboot / network drop | Sessions keep running on the host; dropped panes **reconnect automatically** when you're back |

When the connection drops (closing the lid, changing networks), a pane's ssh dies and the pane shows the disconnect message. Macterm reconnects those panes for you — when the Mac wakes, when you return to the app, or when you select the project — reattaching each one's still-running session, scrollback included. No timer is involved: an unreachable host is retried a bounded number of times per return, not polled. Turn it off with **Settings → General → Remote Projects → Reconnect panes after a dropped connection** (worth doing for a Touch ID-gated key, where every new connection prompts — see Troubleshooting).

Tab titles work like local panes: the tab shows the running program's name (`btop`, `hx`), falling back to the host name when idle. Program-reported titles are picked up too.

## Layouts on remote projects

[Declarative layouts](/docs/declarative-layouts) work unchanged — a central project file whose `path` is a remote spec builds its tabs on the host:

```yaml title="~/.config/macterm/projects/api.yaml"
name: "API (devbox)"
path: "devbox:~/dev/api"
zmxPath: "~/bin/zmx"   # optional — only if auto-detection fails
tabs:
  - run: "npm run dev"
  - name: "Logs"
    cwd: "logs"        # resolves on the remote, relative to the project dir
```

Per-pane `cwd` and `~` resolve on the remote side. **Save layout** works too, writing the current tab/split structure and each pane's running command as its `run:` (read from the same periodic probe that names tabs, so a command started a moment ago may take a few seconds to become visible). A pane idle at its prompt saves a plain shell leaf, same as a local one.

## Troubleshooting

- **`macterm: zmx not found in PATH on this host (…)`** in the pane — zmx isn't in a directory the non-interactive ssh PATH covers. Either move it to `~/bin` or `~/.local/bin`, or set the project's **zmx path** to its absolute location. The pane stays open as a plain shell so you can investigate.
- **`macterm: cannot cd to …`** — the project directory doesn't exist on the host. The pane drops to a shell in the home directory.
- **Connection errors** (unreachable host, failed auth) show ssh's own message on a "press any key to close" screen.
- **Slow tab/split opening** — each pane is its own ssh connection; add `ControlMaster` to your ssh config (example above) to multiplex them over one connection.
- **Touch ID (or another per-connection auth prompt) appears repeatedly** — live tab naming polls the host over short background ssh connections, and a biometric-gated key prompts on each one. Cancel the prompt once and Macterm stops polling that host until you open a new pane on it (tabs fall back to the host name; program-reported titles keep working). To get live naming *and* a single authentication, add `ControlMaster` (example above) — the background polls then reuse the pane's already-authenticated connection and never prompt.
- **To never see a background-triggered prompt at all**, turn off **Settings → General → Remote Projects → Background SSH connections**. The only connections Macterm then opens are the panes' own, plus a one-shot `zmx kill` when you explicitly close a pane (cancel that prompt and the session just stays running on the host). Trade-offs: remote tabs show the host name (program-reported titles keep working), Save Layout can't capture remote `run:` commands, orphaned-session cleanup on the host stops, and closing a remote pane only warns when a running command is positively detected via [shell integration](https://ghostty.org/docs/features/shell-integration) on the host — without it, closes don't warn.

> Your dotfiles still apply *inside* remote panes — the session starts your login shell on the host as usual. Macterm just never runs them in its own connection plumbing, so a `.profile` that `exec`s another shell can't interfere with pane startup.

## Limitations

- zmx must be preinstalled on the host — there's no upload/install flow yet.
- Orphaned sessions on a remote host (a pane closed while the host was unreachable, so the kill never landed) are cleaned up automatically — but only sessions this Macterm installation has marked as its own, so on a shared machine someone else's sessions are never touched. A session orphaned before it was ever marked stays for you to `zmx ls` / `zmx kill` by hand.
- Features that assume a local working directory — like **Replace Project Path with Current Dir** — are disabled for remote projects.
