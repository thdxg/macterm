# How this fork differs from upstream zmx

This fork is the session daemon of [Macterm](https://github.com/thdxg/macterm).
It no longer syncs with [upstream zmx](https://github.com/neurosnap/zmx).

- **Base:** upstream `v1.0.1` (`a35f00a2118b15a5e9d522a43035c8d7487df9b7`).
- **Upstream fixes** are copied by hand, with their tests, when one is worth
  it. To see what upstream did since the base:
  `git remote add upstream https://github.com/neurosnap/zmx.git`, then
  `git fetch upstream && git log a35f00a..upstream/main`.
- **Each change below was a patch** (`.github/downstream/00NN-*.patch`) that a
  daily sync applied again on top of upstream. The code now holds the changes
  directly. The numbers stay as names, because Macterm's history cites them.
  `77fc677` is the last commit that has the patch files:
  `git show 77fc677:.github/downstream/<name>` prints one.

## Changes

### 0003: a client claims leadership without input

zmx gives leadership (the size of the pty) to the client that sends user
input. A GUI that shows one session in two panes needs to move it on a click,
without a keystroke reaching the program.

- An IPC tag `Claim` (192), and an APC sequence that the client removes from
  stdin before it forwards the rest (`util.ClaimFilter`). A claim can share a
  read with typed keys, and a sequence can be split between reads.
- Code: `src/ipc.zig`, `src/util.zig`, `src/loop.zig`.
- Tests: `test/leader.bats`, `test/claim_leader.py`.

### 0004: the daemon is its own responsible process on macOS

macOS gives privacy permissions (Local Network, TCC) to a process's
responsible process, which is fixed at spawn. A session that outlived the app
that started it belonged to nothing, and its programs got `EHOSTUNREACH` on
the local network with no prompt (macterm#419).

- The daemon starts itself again as `zmx __daemon` with
  `POSIX_SPAWN_SETEXEC` and `responsibility_spawnattrs_setdisclaim`: same pid,
  session and fds. Its state rides `ZMX_DAEMON_*` variables, which the child
  that execs the shell removes. Linux is unchanged.
- No process that keeps running calls `unsetenv`: zig 0.17's `std.Io` caches
  the environment block and panics on a shortened one.
- Code: `src/daemonize.zig`, `src/main.zig`, `src/loop.zig`.
- Test: `test/daemon_responsibility.bats` (Darwin only).

### 0005: attach creates a session quietly

`zmx attach` printed `session "<name>" created` and then cleared the screen.
In a pane one or two rows tall, the line scrolled into scrollback and came
back when the pane grew (macterm#487). Attach now uses upstream's `quiet`
flag. `zmx run` still prints the line.

- Code: `src/client.zig`. Test: `test/attach_create.bats`.

### 0006: reattach replays the mouse mode set last

The terminal formatter replays the mouse format and event modes in numeric
order, not in the order the program set them. crossterm sets `?1015h` and
then `?1006h`, so a reattached client got urxvt reports and right click
stopped working. `serializeTerminalState` sets the effective modes again after
the replay. Remove this when the formatter replays the terminal's flags
itself.

- Code: `src/terminal.zig`.

### 0007, 0008, 0009: reattach replays logical lines

On reattach the daemon resizes its terminal to the client and serializes a
snapshot. A client that attaches before its window has its real size (a
placeholder grid, or Macterm's incubator) got rows cut at that width for good.

- 0007: the scrollback phase joins soft-wrapped rows, so the client reflows
  them at its own width.
- 0009: the visible-screen phase does the same. The client has the width the
  terminal was resized to, so the cursor lands on the same row.
- 0008: upstream adopted the linefeeds before the `ED 2` clear that keep the
  last scrollback rows (186393f). Only its tests stayed.
- Code and tests: `src/terminal.zig`.

### 0010: the daemon reports the foreground process

A frontend names a tab after the foreground program, warns before it closes a
busy pane, and shows an agent's logo. Over ssh it had to ask the host every
few seconds, and the answer was a round trip old (macterm#695).

- A client started with `ZMX_FOREGROUND_EVENTS` subscribes. The daemon reads
  the pty's foreground process group before it forwards each chunk of output,
  and every 500 ms, and sends a `Foreground` message (tag 193) when it changes.
  The client writes it into stdout as an APC sequence, in front of the output
  it precedes.
- The report is `zmx;foreground;<idle>;<shell>;<comm>;<args>`. The variable
  and the prefix are a wire contract with Macterm.
- The daemon removes the variable in the child that execs the shell, so a
  nested `zmx attach` does not subscribe. A daemon that does not know the tag
  replies `Unsupported`, and the client ignores it.
- Code: `src/foreground.zig`, `src/ipc.zig`, `src/client.zig`,
  `src/daemonize.zig`, `src/loop.zig`, `src/main.zig`.
- Tests: `src/foreground.zig`, `src/test.zig`.

### Retired

- 0001 (cast `log_mode`) and 0002 (portable signal type): upstream fixed both.
- 0011 (the Linux guard of 0004): folded into 0004.

## Wire tags

The fork's IPC tags start at 192, far from upstream's sequence: `Claim` is
192, `Foreground` is 193. The next one is 194.

## CI

- `test.yml` builds zmx and runs the Zig tests (`zig build test`) on Linux
  and macOS, on every pull request and every push to `main`. The bats tests
  and the Python tests in `test/` do not run in CI.
- `build-zmx.yml` publishes the release that Macterm pins.
