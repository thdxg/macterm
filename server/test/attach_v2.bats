#!/usr/bin/env bats
# `zmx connect` (src/attach.zig): the pane's client of a v2 session. It runs
# on a pty here (test/ptyrun.py); test/v2client.py is a second client.

load test_helper

setup_file() {
  export PYTHONPATH="$BATS_TEST_DIRNAME"
}

# As in session_v2.bats.
setup() {
  ZMX="${ZMX:-$REPO_DIR/zig-out/bin/zmx}"
  if [[ ! -x "$ZMX" ]]; then
    (cd "$REPO_DIR" && zig build)
  fi
  export ZMX
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

@test "connect: attach and type, the size reaches the pty, and Ctrl-\\ detaches" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
from ptyrun import connect
from v2client import Client
p = connect("s1", cols=100, rows=30)
p.type("stty size; printf 'mark-%s\\n' 42\r")
p.wait_output("mark-42")
assert b"30 100" in p.output, p.output
p.type(b"\x1c")
assert p.wait_exit() == 0
# The session lives on.
c = Client("s1")
c.wait_msg("state")
PY
}

@test "connect: a new size of the terminal reaches the pty" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
from ptyrun import connect
p = connect("s1", cols=80, rows=24)
p.type("stty size; printf 'ok-%s\\n' 1\r")
p.wait_output("ok-1")
assert b"24 80" in p.output, p.output
# The pty sends SIGWINCH to the client, which is in its foreground.
p.resize(120, 40)
for i in range(2, 50):
    p.type("stty size; printf 'ok-%%s\\n' %d\r" % i)
    p.wait_output("ok-%d" % i)
    if b"40 120" in p.output:
        break
assert b"40 120" in p.output, p.output[-300:]
p.type(b"\x1c")
assert p.wait_exit() == 0
PY
}

@test "connect: Ctrl-\\ detaches while the session floods output" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
from ptyrun import connect
p = connect("s1")
p.type("yes flood\r")
p.wait_output("flood\r\nflood")
p.type(b"\x1c")
assert p.wait_exit(timeout=5) == 0
PY
}

@test "connect: a session that ends with no exit status is an error" {
  "$ZMX" session s1 -- /bin/sh
  pid=$(python3 "$BATS_TEST_DIRNAME/v2client.py" pid s1)
  python3 - "$pid" <<'PY'
import os, signal, sys
from ptyrun import connect
p = connect("s1")
p.wait_output("\x1b[2J")
os.kill(int(sys.argv[1]), signal.SIGKILL)
st = p.wait_exit()
assert st == 1, (st, p.output[-300:])
assert b'session "s1" closed' in p.output, p.output[-300:]
PY
}

@test "connect: a reattach shows the snapshot" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
from ptyrun import connect
p = connect("s1")
p.type("printf 'snap-%s\\n' 7\r")
p.wait_output("snap-7")
p.type(b"\x1c")
assert p.wait_exit() == 0

q = connect("s1")
q.wait_output("snap-7")
q.type(b"\x1c")
assert q.wait_exit() == 0
PY
}

@test "connect: the claim APC becomes a claim and never reaches the shell" {
  # `cat -v` shows any ESC that it reads as ^[, and the pty's echo does too.
  "$ZMX" session s1 -- /bin/cat -v
  python3 - <<'PY'
from ptyrun import connect
from v2client import Client
a = Client("s1")
a.attach(80, 24)
assert a.wait_msg("lead")["leader"] is True

p = connect("s1")
p.wait_output("\x1b[2J")
p.type(b"\x1b_zmx;claim\x1b\\")
assert a.wait_msg("lead", count=2)["leader"] is False
# Split, as a pty write can be: the filter holds the first half.
p.type(b"one\x1b_zmx;")
p.type(b"claim\x1b\\two\r")
a.wait_output("onetwo")
assert b"^[" not in a.output and b"claim" not in a.output, a.output
p.type(b"\x1c")
assert p.wait_exit() == 0
PY
}

@test "connect: the shell's exit status is the exit code" {
  "$ZMX" session s1 -- /bin/sh -c 'exit 7'
  python3 - <<'PY'
from ptyrun import connect
assert connect("s1").wait_exit() == 7
PY
}

# fake_session <name> <level> <min_level> [refuse_needs]: a socket in the
# runtime directory that sends a session's hello, and a refusal when
# refuse_needs is set. It answers one connection and exits when the client
# closes it. It must not close first: the client writes its hello as a header
# and a body, and a close between the two fails the client's write (EPIPE).
fake_session() {
  mkdir -p -m 700 "$MACTERM_RUNTIME_DIR"
  python3 - "$@" 3>&- <<'PY' &
import os, socket, sys
from v2client import pack, frame, MSG, runtime_dir
name, level, min_level = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
needs = int(sys.argv[4]) if len(sys.argv) > 4 else None
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(os.path.join(runtime_dir(), name))
s.listen(1)
open(os.path.join(runtime_dir(), name + ".ready"), "w").close()
c, _ = s.accept()
c.sendall(frame(0, MSG, pack({"level": level, "min_level": min_level, "build": "old",
                              "role": "session", "epoch": 1, "caps": []})))
if needs is not None:
    c.sendall(frame(0, MSG, pack({"reason": "level_too_low", "needs_level": needs})))
while c.recv(4096):
    pass
PY
  until [[ -e "$MACTERM_RUNTIME_DIR/$1.ready" ]]; do sleep 0.05; done
}

@test "connect: a session that needs a newer level refuses with a message" {
  fake_session s1 9 9 9
  run "$ZMX" connect s1 </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *'session "s1" needs protocol level 9 or later, and this build speaks level 2'* ]]
}

@test "connect: a session of a level under ours is refused with a message" {
  fake_session s1 0 0
  run "$ZMX" connect s1 </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *'session "s1" speaks protocol level 0, and this build needs level 1 or later'* ]]
}

@test "connect: no session, and a bad name, are errors" {
  mkdir -p -m 700 "$MACTERM_RUNTIME_DIR"
  run "$ZMX" connect nothing </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *'no session "nothing"'* ]]
  run "$ZMX" connect ../x </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *'invalid session name'* ]]
}
