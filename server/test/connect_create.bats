#!/usr/bin/env bats
# `zmx connect <name> -- <command>` (src/attach.zig): with no session of the
# name, the client asks the server to make one, and starts the server when
# nothing answers. The session gets the client's folder, environment and
# terminal size. This is how a Macterm pane starts its v2 session.

load test_helper

setup_file() {
  export PYTHONPATH="$BATS_TEST_DIRNAME"
}

# As in server_v2.bats.
setup() {
  ZMX="${ZMX:-$REPO_DIR/zig-out/bin/zmx}"
  if [[ ! -x "$ZMX" ]]; then
    (cd "$REPO_DIR" && zig build)
  fi
  RT="$(mktemp -d "${TMPDIR:-/tmp}/rt.XXXXXX")"
  export MACTERM_RUNTIME_DIR="$RT/run"
  export ZMX RT
}

teardown() {
  local sock pid
  if [[ -S "$MACTERM_RUNTIME_DIR/.server" ]]; then
    pid=$(python3 "$BATS_TEST_DIRNAME/v2client.py" server-pid 2>/dev/null) && kill -KILL "$pid" 2>/dev/null || true
  fi
  for sock in "$MACTERM_RUNTIME_DIR"/*; do
    [[ -S "$sock" ]] || continue
    pid=$(python3 "$BATS_TEST_DIRNAME/v2client.py" pid "$(basename "$sock")" 2>/dev/null) || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  rm -rf "$RT"
}

@test "connect --: makes the session through a server it starts, with its folder, environment and size" {
  mkdir -p "$RT/work"
  (cd "$RT/work" && CREATE_MARK=from-the-pane python3 - <<'PY'
import os
from ptyrun import Pty
from v2client import ServerClient
p = Pty([os.environ["ZMX"], "connect", "s1", "--", "/bin/sh"], cols=90, rows=20)
p.type("pwd; stty size; printf 'env-%s-%s\\n' \"$CREATE_MARK\" \"$MACTERM_SESSION\"\r")
p.wait_output("env-from-the-pane-s1")
assert (os.path.basename(os.environ["RT"]) + "/work\r\n").encode() in p.output, p.output
assert b"20 90" in p.output, p.output
c = ServerClient()
assert list(c.sessions()) == ["s1"], c.sessions()
p.type(b"\x1c")
assert p.wait_exit() == 0
PY
  )
}

@test "connect --: the runtime directory in the session is the server's" {
  python3 - <<'PY'
import os
from ptyrun import Pty
p = Pty([os.environ["ZMX"], "connect", "s1", "--", "/bin/sh"], cols=80, rows=24)
p.type("printf 'rt-%s\\n' \"$MACTERM_RUNTIME_DIR\"\r")
p.wait_output("rt-" + os.environ["MACTERM_RUNTIME_DIR"])
p.type(b"\x1c")
assert p.wait_exit() == 0
PY
}

@test "connect --: a session that exists is attached, and the command is not run again" {
  python3 - <<'PY'
import os
from ptyrun import Pty
argv = [os.environ["ZMX"], "connect", "s1", "--", "/bin/sh"]
p = Pty(argv)
p.type("KEEP=kept-42; printf 'first-%s\\n' 1\r")
p.wait_output("first-1")
p.type(b"\x1c")
assert p.wait_exit() == 0
q = Pty(argv)
q.type("printf 'again-%s\\n' \"$KEEP\"\r")
q.wait_output("again-kept-42")
q.type(b"\x1c")
assert q.wait_exit() == 0
PY
}

@test "connect --: the shell's exit code is the client's" {
  python3 - <<'PY'
import os
from ptyrun import Pty
p = Pty([os.environ["ZMX"], "connect", "s1", "--", "/bin/sh", "-c", "exit 7"])
assert p.wait_exit() == 7, p.output
PY
}

@test "connect with no --: a missing session is not made" {
  run "$ZMX" connect s1
  [ "$status" -ne 0 ]
  [[ "$output" == *'no session "s1"'* ]]
  [ ! -S "$MACTERM_RUNTIME_DIR/.server" ]
}

@test "session.create: an environment entry with no = is refused" {
  python3 - <<'PY'
import subprocess, os
subprocess.run([os.environ["ZMX"], "server"], check=True)
from v2client import ServerClient
c = ServerClient()
r = c.request("session.create", id="s1", env=[b"NOEQUALS"])
assert r.get("err", {}).get("code") == "invalid_args", r
PY
}
