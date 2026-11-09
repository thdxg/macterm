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
(`src/protocol/`), not the zmx IPC above. The server (below)
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
  `exit`, `take` and `end`.
- **Back-pressure.** Each client has a queue of at most 1 MiB. Over it, the
  session drops the queue and sends a snapshot of the screen when the client
  takes data again. The pty is always read.
- **Exit status.** The session keeps the shell's status and sends `exit` to
  each client until one sends `take`. Then it ends.
- On macOS it starts itself again disclaimed (change 0004), as
  `__session <name>`.

## The v2 server

`zmx server` starts the server (`src/server.zig`) unless one answers on its
socket, and returns when the socket accepts connections. There is one for
each user and machine. It holds no pty, and local pane bytes do not go
through it: a client attaches to the session's own socket. The app will
start it (design/001, A). Nothing calls it yet.

- **Socket.** `<dir>/.server`, mode 0600, in the runtime directory of the
  sessions, with the same checks. A session name cannot start with a dot.
  Its log is `<dir>/log/.server.log`.
- **Channel 0.** `session.create` (with an id that the client makes; the
  same id again finds the same session), `session.list`, `session.info`,
  `session.kill` and `server.exit`, and the event `session.exit`. The types
  are in `src/protocol/messages.zig`.
- **Sessions.** `session.create` runs `zmx session` (fork and exec of the
  same binary, which does the `setsid` and the disclaim). At start the
  server connects to every session socket in the directory and reads each
  session's state from its `hello` and `state`.
- **Stores nothing.** A session keeps its exit status until a client sends
  `session.kill`. So a server that crashes, or exits for an update with
  `server.exit`, ends no session and loses no status: the next server reads
  them again.
- **Kill.** The server sends `end` to the session, which sends SIGHUP to
  the shell's process group and SIGKILL 0.5 s later. If the session process
  still runs after 3 s, the server sends it SIGKILL: only the first pid that
  the session reported, and only a pid above 1. The reply comes when the
  session process is gone.
- **Folder.** A session with no folder starts in the home folder. The
  server's environment goes to every session.
- **One server.** The server holds `<dir>/.server.lock` locked while it
  runs. Only the holder binds or unlinks the socket, so a start never takes
  the socket of a live server.
- **Exit.** With no session and no client for 5 s, the server exits. It
  unlinks its socket and then lets the lock go; on `server.exit` it does
  this before it replies, so a start that follows starts a new server. A
  client that connects at the moment of an idle exit gets EOF before
  `hello`: it starts a server and connects again.
- **Old builds on a host.** The app installs each build on a host as
  `~/.local/share/macterm/bin/macterm-<key>` (`host/`). A server that runs
  from such a file removes the file of each other build that no session
  reports, when its sessions settled and after each session ends. It never
  removes its own.

## The host scripts

`host/attach.sh` and `host/install.sh` run on a host over the app's ssh
connection (design/005, steps 3 and 4). The app bundles them and sends each
one as `sh -c '<script>' macterm <arguments>`, so they have no single quote.
`attach.sh` execs `macterm-<key> proxy`, or exits 3 when that build is not
there. `install.sh` reads the gzip build on stdin, checks its SHA-256 and
moves it into place. `test/host_install.bats` runs both over a real sshd.

## The v2 attach client

`zmx connect <name>` (`src/attach.zig`) joins the terminal on its stdin and
stdout to a v2 session, as `zmx attach` does for v1. It becomes `macterm
attach` when v1's `attach` goes (design/007 §6). It never starts a session.
`help` does not list it.

- It sends its size at attach, on SIGWINCH, and when it starts to lead.
- v1's claim APC (`ESC _ zmx;claim ESC \`) on stdin becomes the `claim`
  message and never reaches the shell. This is interim, until the GUI feeds
  the surface itself (design/004 §5).
- Ctrl-\ detaches with status 0, unless `ZMX_NO_DETACH_KEY` is set.
- When the shell exits, it exits with the shell's code, or 128 plus the
  signal. It does not send `take`: the exit status is the server's.
- It refuses a session whose level it cannot speak, and says which levels.

## Build and test

Zig 0.17.1. Zig cannot link with Xcode 26.4 or later (zig#31658), so on a
Mac with a newer Xcode, let CI build it (`.github/workflows/server.yml`).

```bash
zig build              # ./zig-out/bin/zmx
zig build test         # Zig tests
bats test/*.bats       # tests against the built binary
```
