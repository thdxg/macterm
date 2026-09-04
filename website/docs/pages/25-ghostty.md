<!-- page:
slug: ghostty
title: Macterm vs. Ghostty
nav: Macterm vs. Ghostty
group: Getting started
description: Macterm is not a Ghostty fork — it links libghostty as its terminal engine and reads your existing Ghostty config, adding a project sidebar, persistent sessions, and remote projects on top.
-->

# Macterm vs. Ghostty

Macterm is not a fork of [Ghostty](https://ghostty.org) and not a reimplementation of it. It **links libghostty** — the terminal library Ghostty itself is built from — and wraps it in its own macOS app.

The terminal is Ghostty's. The workspace around it is Macterm's.

## What comes from libghostty

GPU rendering, escape-sequence handling, scrollback and reflow, font shaping, and key encoding. A TUI that draws correctly in Ghostty draws correctly in Macterm, because it is the same code drawing it.

## What Macterm adds

- A **vertical project sidebar** — work grouped into projects, each with its own tabs, instead of one horizontal tab strip.
- **[Session persistence](/docs/session-persistence)** — quitting detaches your shells rather than killing them.
- **[Remote projects](/docs/remote-projects)** — a project whose directory lives on another machine, with panes that persist on the host.
- **[Pinned tabs](/docs/pinned-tabs)**, **[declarative layouts](/docs/declarative-layouts)**, and a **[control CLI](/docs/cli)**.

## Your config carries over

Macterm reads your existing Ghostty config from the same locations Ghostty does — theme, font, palette, keybinds. Nothing is copied or converted; it is the same file.

A short list of keys is overridden, all of them window chrome Macterm draws itself. [Configuration](/docs/configuration) lists them.

## Which should I use?

**Ghostty** if you want the terminal on its own: mature, cross-platform, maintained by its author, and with no opinion about how you organize your work.

**Macterm** if you are on macOS and what you keep fighting is session management — shells that survive quitting, projects instead of tabs, and a directory on a server treated like a directory on your Mac.

Running both is fine. They share the config file, and their sessions are independent.

> The library Macterm links is `ghostty-internal`, which upstream does not support for external use. Macterm pins one specific build of it rather than tracking upstream, and its maintainers owe it no stability promise — so bugs in the terminal itself belong here, not in Ghostty's tracker.
