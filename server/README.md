# server

The session server of Macterm. It keeps each terminal session (a shell or a
program on a pty) running when no window shows it, and lets a client attach
to it again.

It starts as [zmx](https://github.com/neurosnap/zmx) by Eric Bower, MIT
(`LICENSE`), with its history: `git log -- server/` shows it. Macterm's fork,
`thdxg/zmx`, is upstream v1.0.1 plus the changes in `DOWNSTREAM.md`.

The app still bundles the pinned fork release. This folder is not yet the
binary that Macterm ships.

## Commands

`zmx help` lists them: `attach`, `send`, `list`, `get`, `set`, `clear`,
`kill`, `history` and `version`. Macterm v1 calls `attach`, `list`, `kill`,
`set` and `version`. The macOS daemon runs `__daemon` after it starts itself
again (change 0004). `get`, `clear`, `send` and `history` stay for the tests
and for a user at a shell; v2 replaces them with protocol messages.

## Build and test

Zig 0.17.1. Zig cannot link with Xcode 26.4 or later (zig#31658), so on a
Mac with a newer Xcode, let CI build it (`.github/workflows/server.yml`).

```bash
zig build              # ./zig-out/bin/zmx
zig build test         # Zig tests
bats test/*.bats       # tests against the built binary
```
