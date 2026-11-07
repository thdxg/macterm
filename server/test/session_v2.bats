#!/usr/bin/env bats
# The v2 session process (src/session.zig): `zmx session`, its socket in the
# runtime directory, and the frames on it. test/v2client.py is the client.

load test_helper

setup_file() {
  export PYTHONPATH="$BATS_TEST_DIRNAME"
}

# test_helper's setup is v1's (ZMX_DIR); these replace it.
setup() {
  ZMX="${ZMX:-$REPO_DIR/zig-out/bin/zmx}"
  if [[ ! -x "$ZMX" ]]; then
    (cd "$REPO_DIR" && zig build)
  fi
  # Short: a socket path has at most 103 bytes on macOS.
  RT="$(mktemp -d "${TMPDIR:-/tmp}/rt.XXXXXX")"
  export MACTERM_RUNTIME_DIR="$RT/run"
}

teardown() {
  local sock pid
  for sock in "$MACTERM_RUNTIME_DIR"/*; do
    [[ -S "$sock" ]] || continue
    pid=$(python3 "$BATS_TEST_DIRNAME/v2client.py" pid "$(basename "$sock")" 2>/dev/null) || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  rm -rf "$RT"
}

mode_of() {
  if stat -c %a "$1" >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi
}

@test "session: starts, and its socket and directory belong to the user only" {
  run "$ZMX" session s1 -- /bin/sh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -S "$MACTERM_RUNTIME_DIR/s1" ]
  [ "$(mode_of "$MACTERM_RUNTIME_DIR")" = "700" ]
  [ "$(mode_of "$MACTERM_RUNTIME_DIR/s1")" = "600" ]

  run "$ZMX" session s1 -- /bin/sh
  [ "$status" -eq 1 ]
  [[ "$output" == *'already exists'* ]]
}

@test "session: hello, then the state with the pids and the pty" {
  "$ZMX" session --cols 90 --rows 30 s1 -- /bin/sh
  python3 - <<'PY'
from v2client import Client
c = Client("s1")
st = c.wait_msg("state")
h = c.control()[0]
assert h["role"] == "session" and h["level"] >= 1, h
assert st["pid"] > 0 and st["shell_pid"] > 0 and st["pid"] != st["shell_pid"], st
assert st["pty"].startswith(b"/dev/"), st
assert (st["cols"], st["rows"]) == (90, 30), st
PY
}

@test "session: attach and type" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
from v2client import Client
c = Client("s1")
c.attach(80, 24)
assert c.wait_msg("lead")["leader"] is True
c.type("printf 'mark-%s\\n' 42\r")
c.wait_output("mark-42")
PY
}

@test "session: the leader's resize reaches the pty" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
from v2client import Client
c = Client("s1")
c.attach(80, 24)
c.type("stty size; printf 'ok-%s\\n' 1\r")
c.wait_output("ok-1")
assert b"24 80" in c.output, c.output
c.pane("resize", cols=100, rows=30)
c.type("stty size; printf 'ok-%s\\n' 2\r")
c.wait_output("ok-2")
assert b"30 100" in c.output, c.output
PY
}

@test "session: two clients, one leader, and a claim moves the size" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
from v2client import Client
a = Client("s1")
a.attach(80, 24)
assert a.wait_msg("lead")["leader"] is True
b = Client("s1")
b.attach(50, 10)
b.wait_msg("state")
# B does not lead, so its size does not reach the pty.
b.pane("resize", cols=50, rows=10)
a.type("stty size; printf 'ok-%s\\n' 1\r")
a.wait_output("ok-1")
b.wait_output("ok-1")
assert b"24 80" in a.output, a.output
assert not b.messages("lead"), b.messages("lead")

b.pane("claim")
assert b.wait_msg("lead")["leader"] is True
assert a.wait_msg("lead", count=2)["leader"] is False
b.pane("resize", cols=60, rows=20)
b.type("stty size; printf 'ok-%s\\n' 2\r")
b.wait_output("ok-2")
assert b"20 60" in b.output, b.output

# A keystroke from A takes the lead back.
a.type("printf 'ok-%s\\n' 3\r")
assert a.wait_msg("lead", count=3)["leader"] is True
a.wait_output("ok-3")
PY
}

@test "session: a client that attaches later gets a snapshot" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
from v2client import Client
a = Client("s1")
a.attach(80, 24)
a.type("printf 'snap-%s\\n' 5\r")
a.wait_output("snap-5")
a.close()

b = Client("s1")
b.attach(80, 24)
assert b.wait_msg("snapshot.start")["scrollback"] is True
b.wait_msg("snapshot.end")
assert b"snap-5" in b.output, b.output
PY
}

@test "session: a client that stops reading gets a snapshot, and the shell never blocks" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
from v2client import Client
stuck = Client("s1")
stuck.attach(80, 24)
stuck.wait_msg("lead")
# From here, `stuck` reads nothing.

live = Client("s1")
live.attach(80, 24)
live.wait_msg("state")
# 4 MB of output: more than the cap and the socket buffers together.
live.type("head -c 4000000 /dev/zero | tr '\\0' x; printf '\\ndone-%s\\n' 7\r")
live.wait_output("done-7", timeout=120)
live.type("printf 'alive-%s\\n' 9\r")
live.wait_output("alive-9", timeout=10)

# Now `stuck` reads again: what was queued for it, then a snapshot of the
# screen in place of the output it lost.
stuck.wait(lambda: any(m["a"]["scrollback"] is False for m in stuck.messages("snapshot.start")),
           timeout=120, what="the snapshot after the drop")
stuck.wait(lambda: b"alive-9" in stuck.output, timeout=10, what="the screen")
assert len(stuck.output) < 3000000, len(stuck.output)
PY
}

@test "session: the exit status stays across reconnects until a client takes it" {
  "$ZMX" session s1 -- /bin/sh -c 'sleep 1; exit 7'
  sleep 2
  python3 - <<'PY'
import os
from v2client import Client, runtime_dir
for _ in range(2):
    c = Client("s1")
    c.wait_msg("state")
    assert c.wait_msg("exit") == {"code": 7}, c.messages()
    c.close()
c = Client("s1")
c.wait_msg("exit")
c.pane("take")
c.wait_closed()
assert not os.path.exists(os.path.join(runtime_dir(), "s1"))
PY
}

@test "session: a shell that a signal ends reports the signal" {
  "$ZMX" session s1 -- /bin/sh -c 'kill -9 $$'
  python3 - <<'PY'
from v2client import Client
c = Client("s1")
assert c.wait_msg("exit") == {"signal": 9}, c.messages()
c.pane("take")
c.wait_closed()
PY
}

@test "session: a hello under the session's level is refused" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
from v2client import Client
c = Client("s1", level=0, min_level=0)
c.wait_closed()
refuse = c.control()[1]
assert refuse == {"reason": "level_too_low", "needs_level": 1}, c.control()
assert not c.messages(), c.messages()
PY
}

@test "session: a first frame that is not a hello closes the connection" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
from v2client import Client
c = Client("s1", greet=False)
c.type("echo no\r")
c.wait_closed()
assert not c.messages(), c.messages()
PY
}

@test "session: a runtime directory that is not 0700, or is a link, is refused" {
  mkdir -p "$MACTERM_RUNTIME_DIR"
  chmod 755 "$MACTERM_RUNTIME_DIR"
  run "$ZMX" session s1 -- /bin/sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"has a mode other than 0700"* ]]
  [ ! -e "$MACTERM_RUNTIME_DIR/s1" ]

  chmod 700 "$MACTERM_RUNTIME_DIR"
  ln -s "$MACTERM_RUNTIME_DIR" "$RT/link"
  MACTERM_RUNTIME_DIR="$RT/link" run "$ZMX" session s1 -- /bin/sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"is a symbolic link"* ]]
}

@test "session: a peer of another user is refused" {
  # The test opens the directory and the socket to everyone, so that only
  # the session's own peer check stands between that user and the pane.
  if ! sudo -n true 2>/dev/null; then skip "needs sudo to run a client as another user"; fi
  "$ZMX" session s1 -- /bin/sh
  chmod 711 "$RT" "$MACTERM_RUNTIME_DIR"
  chmod 666 "$MACTERM_RUNTIME_DIR/s1"
  run sudo -n -u nobody python3 - "$MACTERM_RUNTIME_DIR/s1" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sys.argv[1])
s.settimeout(5)
print("got %d bytes" % len(s.recv(65536)))
PY
  chmod 700 "$MACTERM_RUNTIME_DIR"
  [ "$status" -eq 0 ]
  [ "$output" = "got 0 bytes" ]
  # The owner still gets in.
  python3 - <<'PY'
from v2client import Client
Client("s1").wait_msg("state")
PY
}
