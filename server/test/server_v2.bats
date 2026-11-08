#!/usr/bin/env bats
# The v2 server (src/server.zig): `zmx server`, its socket in the runtime
# directory, and its requests and events on channel 0. test/v2client.py is
# the client.

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
  if [[ -f "$RT/fake.pid" ]]; then kill "$(<"$RT/fake.pid")" 2>/dev/null || true; fi
  rm -rf "$RT"
}

mode_of() {
  if stat -c %a "$1" >/dev/null 2>&1; then stat -c %a "$1"; else stat -f %Lp "$1"; fi
}

@test "server: starts once, and its socket belongs to the user only" {
  run "$ZMX" server
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -S "$MACTERM_RUNTIME_DIR/.server" ]
  [ "$(mode_of "$MACTERM_RUNTIME_DIR")" = "700" ]
  [ "$(mode_of "$MACTERM_RUNTIME_DIR/.server")" = "600" ]
  first=$(python3 "$BATS_TEST_DIRNAME/v2client.py" server-pid)

  # A second start finds the first server and leaves it.
  run "$ZMX" server
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(python3 "$BATS_TEST_DIRNAME/v2client.py" server-pid)" = "$first" ]
}

@test "server: hello, then a refusal for a low level or a CLI of another build" {
  "$ZMX" server
  python3 - <<'PY'
from v2client import ServerClient
c = ServerClient()
c.wait(lambda: c.control(), what="hello")
h = c.control()[0]
assert h["role"] == "server" and h["level"] >= 1 and h["epoch"] != 0, h

low = ServerClient(level=0, min_level=0)
low.wait_closed()
assert low.control()[1] == {"reason": "level_too_low", "needs_level": 1}, low.control()

cli = ServerClient(role="cli", build="another")
cli.wait_closed()
assert cli.control()[1]["reason"] == "build_mismatch", cli.control()

# A method that the server does not have: an error, and the link stays.
res = c.request("pane.split")
assert res["err"]["code"] == "unknown_method", res
assert c.call("session.list") == {"sessions": []}

# Each start has a new epoch.
import os, signal
from v2client import wait_dead
pid = c.peer_pid()
os.kill(pid, signal.SIGKILL)
wait_dead(pid)
os.system(os.environ["ZMX"] + " server")
again = ServerClient()
again.wait(lambda: again.control(), what="hello")
assert again.control()[0]["epoch"] != h["epoch"]
PY
}

@test "server: create, attach, list, info, kill" {
  "$ZMX" server
  python3 - <<'PY'
import os
from v2client import Client, ServerClient, alive, wait_dead
c = ServerClient()
s = c.call("session.create", id="s1", command=[b"/bin/sh"], cols=90, rows=30, cwd=os.environ["RT"].encode())
assert s["id"] == "s1" and s["state"] == "running", s
assert s["pid"] > 0 and s["shell_pid"] > 0 and (s["cols"], s["rows"]) == (90, 30), s
assert s["pty"].startswith(b"/dev/"), s
assert os.path.exists(os.path.join(os.environ["MACTERM_RUNTIME_DIR"], "s1"))

# A client attaches to the session's own socket, not through the server.
a = Client("s1")
a.attach(90, 30)
a.type("pwd; printf 'mark-%s\\n' 42\r")
a.wait_output("mark-42")
assert os.path.realpath(os.environ["RT"]).encode() in a.output, a.output

# The same id again: the same session, not a second one.
again = c.call("session.create", id="s1", command=[b"/bin/sh"])
assert again["pid"] == s["pid"], again

# Two creates of one new id at the same time start one session.
from v2client import CONTROL
c.send_msg(CONTROL, {"id": 900, "m": "session.create", "a": {"id": "s2", "command": [b"/bin/sh"]}})
c.send_msg(CONTROL, {"id": 901, "m": "session.create", "a": {"id": "s2", "command": [b"/bin/sh"]}})
both = lambda: [v for v in c.control() if isinstance(v, dict) and v.get("re") in (900, 901)]
c.wait(lambda: len(both()) == 2, what="two responses")
assert both()[0]["ok"]["pid"] == both()[1]["ok"]["pid"], both()
c.call("session.kill", id="s2")

assert list(c.sessions()) == ["s1"], c.sessions()
assert c.call("session.info", id="s1")["pid"] == s["pid"]
assert c.request("session.info", id="nope")["err"]["code"] == "not_found"

assert c.call("session.kill", id="s1") == {}
c.wait_event("session.exit", lambda a: a["id"] == "s1")
assert c.sessions() == {}, c.sessions()
assert not os.path.exists(os.path.join(os.environ["MACTERM_RUNTIME_DIR"], "s1"))
wait_dead(s["pid"])
wait_dead(s["shell_pid"])
a.wait_closed()
assert c.request("session.kill", id="s1")["err"]["code"] == "not_found"
PY
}

@test "server: create refuses a bad id or folder, and says why a start failed" {
  "$ZMX" server
  python3 - <<'PY'
from v2client import ServerClient
c = ServerClient()
for args in ({"id": "a/b"}, {"id": ".hidden"}, {"id": "--cwd"}, {"id": "ok", "cwd": b"relative"},
             {"id": "ok", "cwd": b"/tmp\x00x"}, {"id": "ok", "command": [b"sh\x00"]}, {"id": "ok", "cols": 0}):
    res = c.request("session.create", **args)
    assert res["err"]["code"] == "invalid_args", (args, res)
res = c.request("session.create", id="x", cwd=b"/no/such/folder")
assert res["err"]["code"] == "start_failed", res
assert "/no/such/folder" in res["err"]["message"], res
assert c.sessions() == {}
PY
}

@test "server: an exit is an event, and the session keeps its status until a kill" {
  "$ZMX" server
  python3 - <<'PY'
from v2client import ServerClient, alive, wait_dead
c = ServerClient()
s = c.call("session.create", id="e1", command=[b"/bin/sh", b"-c", b"sleep 0.3; exit 7"])
ev = c.wait_event("session.exit")
assert ev == {"id": "e1", "code": 7}, ev
info = c.call("session.info", id="e1")
assert info["state"] == "exited" and info["code"] == 7, info
assert alive(info["pid"]), info

# Another client sees the same status.
d = ServerClient()
assert d.sessions()["e1"]["code"] == 7

c.call("session.kill", id="e1")
assert c.sessions() == {}
wait_dead(info["pid"])
# One exit event for each session.
assert len(c.events("session.exit")) == 1, c.events()
PY
}

@test "server: a kill -9 of the server ends no session, and a new server lists them with their exit status" {
  "$ZMX" server
  python3 - <<'PY'
import os, signal, time
from v2client import Client, ServerClient, alive, wait_dead
c = ServerClient()
run = c.call("session.create", id="run", command=[b"/bin/sh"])
done = c.call("session.create", id="done", command=[b"/bin/sh", b"-c", b"exit 3"])
later = c.call("session.create", id="later", command=[b"/bin/sh"])
c.wait_event("session.exit", lambda a: a["id"] == "done")

server = c.peer_pid()
os.kill(server, signal.SIGKILL)
wait_dead(server)

# With no server, a shell exits, and its session keeps the status.
a = Client("later")
a.attach()
a.type("exit 5\r")
a.wait_msg("exit")
a.close()
time.sleep(0.2)
for s in (run, done, later):
    assert alive(s["pid"]), s

os.system(os.environ["ZMX"] + " server")
n = ServerClient()
got = n.sessions()
assert sorted(got) == ["done", "later", "run"], got
assert got["run"]["state"] == "running" and got["run"]["pid"] == run["pid"], got
assert got["done"]["state"] == "exited" and got["done"]["code"] == 3, got
assert got["later"]["state"] == "exited" and got["later"]["code"] == 5, got

# The new server ends them as the old one would have.
for id in ("run", "done", "later"):
    n.call("session.kill", id=id)
assert n.sessions() == {}
for s in (run, done, later):
    wait_dead(s["pid"])
PY
}

@test "server: server.exit leaves every session running" {
  "$ZMX" server
  python3 - <<'PY'
import os
from v2client import Client, ServerClient, alive, wait_dead
c = ServerClient()
s = c.call("session.create", id="keep", command=[b"/bin/sh"])
old = c.peer_pid()
assert c.call("server.exit") == {}
# The socket is gone when the reply comes, so a start right after it
# starts a new server.
assert not os.path.exists(os.path.join(os.environ["MACTERM_RUNTIME_DIR"], ".server"))
assert os.system(os.environ["ZMX"] + " server") == 0
c.wait_closed()
assert alive(s["pid"])

a = Client("keep")
a.attach()
a.type("printf 'still-%s\\n' here\r")
a.wait_output("still-here")

n = ServerClient()
assert n.peer_pid() != old
assert n.sessions()["keep"]["pid"] == s["pid"]
n.call("session.kill", id="keep")
PY
}

@test "server: a session of another build at the lowest level is listed" {
  "$ZMX" server
  # A session process as an older build answers: the lowest level that the
  # server accepts, another build, a cap and fields that this build does not
  # know.
  python3 - "$RT" <<'PY' &
import os, socket, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
from v2client import pack, frame, unpack, MSG, CONTROL, PANE
rt = sys.argv[1]
open(os.path.join(rt, "fake.pid"), "w").write(str(os.getpid()))
path = os.path.join(os.environ["MACTERM_RUNTIME_DIR"], "old1")
l = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
l.bind(path + ".tmp")
os.rename(path + ".tmp", path)
l.listen(4)
open(os.path.join(rt, "fake.ready"), "w").close()
while True:
    conn, _ = l.accept()
    conn.sendall(frame(CONTROL, MSG, pack({"level": 1, "min_level": 1, "build": "1.0.0-old", "role": "session",
                                            "epoch": 9, "caps": ["later-cap"], "later": True})))
    conn.sendall(frame(PANE, MSG, pack({"t": "state", "a": {"pid": os.getpid(), "shell_pid": os.getpid(),
                                         "pty": b"/dev/ttys999", "cols": 80, "rows": 24, "later": 1}})))
    data = b""
    while len(data) < 9 or len(data) < 9 + int.from_bytes(data[:4], "little"):
        data += conn.recv(4096)
    hello, _ = unpack(data, 9)
    open(os.path.join(rt, "fake.hello.tmp"), "w").write(hello["role"])
    os.rename(os.path.join(rt, "fake.hello.tmp"), os.path.join(rt, "fake.hello"))
PY
  for _ in $(seq 50); do [[ -f "$RT/fake.ready" ]] && break; sleep 0.1; done
  # The server reads sessions at start: a new server finds the fake.
  pid=$(python3 "$BATS_TEST_DIRNAME/v2client.py" server-pid)
  kill -KILL "$pid"
  while kill -0 "$pid" 2>/dev/null; do sleep 0.05; done
  "$ZMX" server
  python3 - <<'PY'
from v2client import ServerClient
c = ServerClient()
s = c.sessions()["old1"]
assert s["state"] == "running" and s["build"] == "1.0.0-old" and s["level"] == 1, s
assert s["pty"] == b"/dev/ttys999", s
PY
  for _ in $(seq 50); do [[ -f "$RT/fake.hello" ]] && break; sleep 0.1; done
  [ "$(<"$RT/fake.hello")" = "server" ]
}

@test "server: exits when it has no session and no client" {
  "$ZMX" server
  python3 - <<'PY'
import os, time
from v2client import ServerClient, alive, wait_dead
c = ServerClient()
pid = c.peer_pid()
c.call("session.create", id="s1", command=[b"/bin/sh"])
c.close()
# A session keeps it running.
time.sleep(6)
assert alive(pid)
c = ServerClient()
c.call("session.kill", id="s1")
# A client alone keeps it running.
time.sleep(6)
assert alive(pid)
c.close()
wait_dead(pid, timeout=10)
assert not os.path.exists(os.path.join(os.environ["MACTERM_RUNTIME_DIR"], ".server"))
PY
}

@test "server: a kill ends a shell that ignores SIGHUP" {
  "$ZMX" server
  python3 - <<'PY'
from v2client import ServerClient, wait_dead
c = ServerClient()
s = c.call("session.create", id="stubborn", command=[b"/bin/sh", b"-c", b"trap '' HUP; while :; do sleep 1; done"])
c.call("session.kill", id="stubborn")
wait_dead(s["pid"])
wait_dead(s["shell_pid"])
assert c.sessions() == {}
PY
}

@test "server: a session whose level is too low is listed as refused, until it ends" {
  # A session that speaks only level 0: the server refuses it.
  python3 - "$RT" <<'PY' &
import os, socket, sys
sys.path.insert(0, os.environ["PYTHONPATH"])
from v2client import pack, frame, MSG, CONTROL
rt = sys.argv[1]
open(os.path.join(rt, "fake.pid"), "w").write(str(os.getpid()))
os.makedirs(os.environ["MACTERM_RUNTIME_DIR"], mode=0o700, exist_ok=True)
path = os.path.join(os.environ["MACTERM_RUNTIME_DIR"], "old0")
l = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
l.bind(path)
l.listen(4)
open(os.path.join(rt, "fake.ready"), "w").close()
while True:
    conn, _ = l.accept()
    try:
        conn.sendall(frame(CONTROL, MSG, pack({"level": 0, "min_level": 0, "build": "0.9.0", "role": "session",
                                                "epoch": 9, "caps": []})))
    except OSError:
        pass  # The server's check connects and closes at once.
    conn.close()
PY
  for _ in $(seq 50); do [[ -f "$RT/fake.ready" ]] && break; sleep 0.1; done
  "$ZMX" server
  python3 - <<'PY'
import os, signal
from v2client import ServerClient, wait_dead
c = ServerClient()
s = c.sessions()["old0"]
assert s["state"] == "refused" and s["build"] == "0.9.0" and s["level"] == 0, s
assert "pid" not in s, s
assert c.request("session.kill", id="old0")["err"]["code"] == "refused"

pid = int(open(os.path.join(os.environ["RT"], "fake.pid")).read())
os.kill(pid, signal.SIGKILL)
wait_dead(pid)
assert c.sessions() == {}, c.sessions()
PY
}
