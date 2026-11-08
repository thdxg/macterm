# server

The session server of Macterm. It keeps each terminal session (a shell or a
program on a pty) running when no window shows it, and lets a client attach
to it again.

It starts as [zmx](https://github.com/neurosnap/zmx) by Eric Bower, MIT
(`LICENSE`). Macterm's fork, `thdxg/zmx`, is upstream v1.0.1 plus the changes
in `DOWNSTREAM.md`. Its history stays in that repository.

The app bundles the build of this folder at the same commit
(`scripts/build-server.sh`). `mise run setup` downloads the prebuilt of this
tree from the `server-prebuilt` release, or builds it with Zig when the tree
has changes that are not committed or no prebuilt exists.

## Commands

`zmx help` lists them: `attach`, `send`, `list`, `get`, `set`, `clear`,
`kill`, `history` and `version`. Macterm v1 calls `attach`, `list`, `kill`,
`set` and `version`. The macOS daemon runs `__daemon` after it starts itself
again (change 0004). `get`, `clear`, `send` and `history` stay for the tests
and for a user at a shell; v2 replaces them with protocol messages.

## The v2 session

`zmx session [--cols N] [--rows N] [--cwd DIR] <name> [--] [command...]`
starts a v2 session process (`src/session.zig`) and returns when its socket
accepts connections. It is the shell's parent, and it speaks the v2 frames
(`src/protocol/`), not the zmx IPC above. The server (Macterm issue 0048)
runs it; `help` does not list it.

- **Socket.** `<dir>/<name>`, mode 0600. `<dir>` is `MACTERM_RUNTIME_DIR`,
  else `$XDG_RUNTIME_DIR/macterm`, else `$TMPDIR/macterm` on macOS, else
  `~/.local/state/macterm/run`. The session refuses to start unless `lstat`
  finds a directory of this user with mode 0700 (`src/runtime.zig`). It
  closes a connection from another uid before it sends anything. Its log is
  `<dir>/log/<name>.log`.
- **Frames.** Each side sends `hello` on channel 0 first. The pane is
  channel 1: `bytes` in and out, and the messages in
  `src/protocol/messages.zig` ("A session's pane channel"): `state`,
  `attach`, `resize`, `claim`, `lead`, `snapshot.start`, `snapshot.end`,
  `exit` and `take`.
- **Back-pressure.** Each client has a queue of at most 1 MiB. Over it, the
  session drops the queue and sends a snapshot of the screen when the client
  takes data again. The pty is always read.
- **Exit status.** The session keeps the shell's status and sends `exit` to
  each client until one sends `take`. Then it ends.
- On macOS it starts itself again disclaimed (change 0004), as
  `__session <name>`.

## Build and test

Zig 0.17.1. Zig cannot link with Xcode 26.4 or later (zig#31658), so on a
Mac with a newer Xcode, let CI build it (`.github/workflows/server.yml`).

```bash
zig build              # ./zig-out/bin/zmx
zig build test         # Zig tests
bats test/*.bats       # tests against the built binary
```
