<!-- page:
slug: tmux
title: Macterm vs. tmux
nav: Macterm vs. tmux
group: Getting started
description: Macterm as a native macOS tmux alternative — persistent sessions and splits as real UI, with no prefix key. What replaces what, and what tmux still does better.
-->

# Macterm vs. tmux

Most people run tmux inside a terminal for two reasons: **sessions that survive**, and **splits**. Macterm does both natively, so if those are your reasons, you can stop running it.

You are not required to. tmux works fine inside a Macterm pane — it is just a program, and the terminal underneath handles it correctly.

## What replaces what

| tmux | Macterm |
| --- | --- |
| session | project — a directory with its own tabs, in the sidebar |
| window | tab, listed under its project |
| pane | pane, split from a tab |
| detach / `tmux attach` | quitting and relaunching the app |
| `.tmux.conf` layout scripting | [a YAML project file](/docs/declarative-layouts) |
| `tmux send-keys` | [the `macterm` CLI](/docs/cli) |
| tmux-resurrect / continuum | built in — nothing to install |

## No prefix key

Macterm's shortcuts are ordinary macOS shortcuts, not keys a program in your terminal has to intercept, so there is nothing to press first and nothing for your editor to collide with.

A binding can also be handed back to the program when you want it: [passthrough](/docs/configuration) lets one chord move between nvim's own splits while you are inside nvim, and between Macterm's panes when you reach the edge.

## Persistence works differently

tmux keeps shells alive by being a server your terminal attaches to. Macterm does the same with [`zmx`](/docs/session-persistence), one session per pane — but you never address it directly. Quitting detaches; launching reattaches.

Two consequences worth knowing:

- **Closing is the destructive act, not quitting.** Closing a pane, tab, or project ends its shell — and you are asked first if something is still running.
- **Local sessions do not survive a reboot**, same as tmux's server. Panes respawn in their last working directory.

## Over SSH, it is inverted

The usual remote workflow is `ssh host`, then `tmux attach` on the far side. A [remote project](/docs/remote-projects) points Macterm at `host:~/dev/api` instead, and every pane in it is a persistent session **on the host**, reattached automatically.

Because the host owns the session, those panes survive quitting, a dropped connection, and rebooting your Mac. There is no `tmux attach` to type.

## What tmux still does better

- **It runs anywhere.** tmux is on every server you will ever touch; Macterm is a macOS app.
- **Two clients on one session** — pair programming, or following a session from a second machine — has no Macterm equivalent.
- **It is terminal-agnostic.** tmux's state lives outside any one app; Macterm's projects and tabs are Macterm's.
