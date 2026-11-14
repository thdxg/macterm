#!/usr/bin/env bats
# The events of a v2 session (src/events.zig, src/session.zig): title, cwd,
# foreground, marks, progress, bell, the heartbeat, the run status and the
# program status (OSC 7501), from a shell that a test types into. test/v2client.py is the client; `zmx
# connect` runs on a pty (test/ptyrun.py).

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

@test "events: title, cwd, bell, progress and the heartbeat" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
import time
from v2client import Client
c = Client("s1")
c.attach()
c.wait_msg("state")
c.type("printf '\\033]2;my title\\007\\033]7;file://h/tmp/a%%20b\\007\\007\\033]9;4;1;42\\007'; printf 'done-%s\\n' 1\r")
c.wait_output("done-1")
assert c.wait_msg("title")["title"] == b"my title"
assert c.wait_msg("cwd")["url"] == b"file://h/tmp/a%20b"
c.wait_msg("bell")
assert c.wait_msg("progress") == {"state": "set", "percent": 42}
# The heartbeat: a new one after a quiet window.
beats = len(c.messages("activity"))
time.sleep(0.6)
c.type("printf 'beat-%s\\n' 2\r")
c.wait_output("beat-2")
c.wait_msg("activity", count=beats + 1)
# A progress report that sets work starts a run.
assert c.wait_msg("status")["state"] == "running"

# In one write, an event goes after the output before its sequence and
# before the output after it.
c.type("printf '%s-1\\n\\033]2;between\\007%s-2\\n' aa bb\r")
c.wait_output("bb-2")
c.wait(lambda: any(m["a"]["title"] == b"between" for m in c.messages("title")), what="the title")
def frame_at(pred):
    return next(i for i, (ch, kind, v) in enumerate(c.frames) if ch == 1 and pred(kind, v))
title_at = frame_at(lambda kind, v: kind == 0 and v["t"] == "title" and v["a"]["title"] == b"between")
before_at = frame_at(lambda kind, v: kind == 1 and b"aa-1" in v)
after_at = frame_at(lambda kind, v: kind == 1 and b"bb-2" in v)
assert before_at < title_at < after_at, (before_at, title_at, after_at)
PY
}

@test "events: marks carry the command and the exit code, and the status follows them" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
from v2client import Client
c = Client("s1")
c.attach()
c.wait_msg("state")
c.type("printf '\\033]133;A\\007$ \\033]133;B\\007'; printf '\\033]133;C;cmdline_url=make%%20test\\007'; sleep 0.2; printf '%s-%s\\n\\033]133;D;3\\007' tail 9\r")
end = c.wait_msg("mark", count=4)
kinds = [m["a"]["kind"] for m in c.messages("mark")]
assert kinds[:4] == ["prompt", "input", "output", "end"], kinds
assert c.messages("mark")[2]["a"]["command"] == b"make test"
assert end == {"kind": "end", "command": b"make test", "exit_code": 3}, end
# The command's last output comes before its end mark, also in one write.
end_at = next(i for i, (ch, kind, v) in enumerate(c.frames) if kind == 0 and ch == 1 and v["t"] == "mark" and v["a"]["kind"] == "end")
assert b"tail-9" in b"".join(v for ch, kind, v in c.frames[:end_at] if kind == 1)
assert c.wait_msg("status", count=1)["state"] == "running"
# A nonzero exit code is not a failed run.
assert c.wait_msg("status", count=2) == {"state": "done", "failed": False}
PY
}

@test "events: a title flood coalesces, and the newest title arrives" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
import time
from v2client import Client
c = Client("s1")
c.attach()
c.wait_msg("state")
start = time.time()
c.type("awk 'BEGIN { for (i = 0; i < 5000; i++) printf \"\\033]0;t%d\\007\", i }'; printf 'flood-%s\\n' done\r")
c.wait_output("flood-done")
elapsed_ms = (time.time() - start) * 1000
c.wait(lambda: any(m["a"]["title"] == b"t4999" for m in c.messages("title")), what="the newest title")
titles = [m["a"]["title"] for m in c.messages("title")]
# At most one title at once and one at the end of each 16 ms window.
assert len(titles) <= 2 * (elapsed_ms / 16 + 2), (len(titles), elapsed_ms)
assert len(titles) < 1000, len(titles)
assert titles[-1] == b"t4999", titles[-3:]
PY
}

@test "events: the foreground follows the program that holds the pty" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
from v2client import Client
c = Client("s1")
c.attach(foreground=True)
first = c.wait_msg("foreground")
assert first["idle"] is True, first
c.type("sleep 30\r")
def last():
    return c.messages("foreground")[-1]["a"]
# The group can change before the child `exec`s sleep: wait for its name.
c.wait(lambda: b"sleep" in last()["comm"], what="the sleep foreground")
assert last()["idle"] is False and last()["args"] == b"sleep 30", last()
c.type(b"\x03")
c.wait(lambda: last()["idle"] is True, what="the idle foreground")
PY
}

@test "events: a client that connects later gets the current state" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
from v2client import Client
a = Client("s1")
a.attach()
a.wait_msg("state")
a.type("printf '\\033]2;kept\\007\\033]7;file:///srv\\007\\033]9;4;3\\007'; printf 'set-%s\\n' 1\r")
a.wait_output("set-1")
a.wait_msg("status")

b = Client("s1")
b.wait_msg("state")
assert b.wait_msg("title")["title"] == b"kept"
assert b.wait_msg("cwd")["url"] == b"file:///srv"
assert b.wait_msg("progress")["state"] == "indeterminate"
assert b.wait_msg("status")["state"] == "running"
b.attach(foreground=True)
assert b.wait_msg("foreground")["idle"] is True
PY
}

@test "events: only a client that asks gets the foreground" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
from v2client import Client
a = Client("s1")
a.attach()
b = Client("s1")
b.attach(foreground=True)
b.wait_msg("foreground")
b.type("sleep 30\r")
b.wait(lambda: b"sleep" in b.messages("foreground")[-1]["a"]["comm"], what="the sleep foreground")
assert a.messages("foreground") == [], a.messages("foreground")
# A refresh drops the queue: the client that asked gets the foreground
# again, and the other client still gets none.
count = len(b.messages("foreground"))
b.pane("refresh")
b.wait_msg("foreground", count=count + 1)
ends = len(a.messages("snapshot.end"))
a.pane("refresh")
a.wait_msg("snapshot.end", count=ends + 1)
assert a.messages("foreground") == [], a.messages("foreground")
PY
}

# An idle session with only clients that did not ask for the foreground
# does not wake. With a client that asked, it wakes each 500 ms. macOS counts
# each wakeup of the session's poll as an interrupt wakeup
# (`proc_pid_rusage`, as scripts/_harness.py reads it), Linux as a voluntary
# context switch.
@test "events: an idle session wakes only for a client that wants the foreground" {
  "$ZMX" session s1 -- /bin/sh
  SESSION_PID=$(python3 "$BATS_TEST_DIRNAME/v2client.py" pid s1) python3 - <<'PY'
import ctypes, os, struct, sys, time
from v2client import Client
pid = int(os.environ["SESSION_PID"])
def switches():
    if sys.platform == "darwin":
        buf = ctypes.create_string_buffer(512)
        # RUSAGE_INFO_V2; ri_interrupt_wkups is at offset 40.
        assert ctypes.CDLL("/usr/lib/libproc.dylib").proc_pid_rusage(pid, 2, buf) == 0
        return struct.unpack_from("Q", buf.raw, 40)[0]
    for line in open("/proc/%d/status" % pid):
        if line.startswith("voluntary_ctxt_switches:"):
            return int(line.split()[1])
def wakeups(seconds=3):
    time.sleep(0.5)
    before = switches()
    time.sleep(seconds)
    return switches() - before
a = Client("s1")
a.attach()
a.type("printf 'idle-%s\\n' 1\r")
a.wait_output("idle-1")
quiet = wakeups()
assert quiet <= 1, quiet
b = Client("s1")
b.attach(foreground=True)
b.wait_msg("foreground")
polled = wakeups()
assert polled >= 4, polled
PY
}

@test "events: connect writes the foreground as v1's APC only when asked" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
import os, time
from ptyrun import Pty
os.environ["ZMX_FOREGROUND_EVENTS"] = "1"
p = Pty([os.environ["ZMX"], "connect", "s1"])
p.wait_output("\x1b_zmx;foreground;1;")
p.type("sleep 30\r")
p.wait_output(";sleep 30\x1b\\")
p.type(b"\x03")
deadline = time.time() + 10
while p.output.count(b"\x1b_zmx;foreground;1;") < 2:
    assert time.time() < deadline, p.output[-300:]
    p._read()
p.type(b"\x1c")
assert p.wait_exit() == 0

del os.environ["ZMX_FOREGROUND_EVENTS"]
q = Pty([os.environ["ZMX"], "connect", "s1"])
q.type("printf 'plain-%s\\n' 1\r")
q.wait_output("plain-1")
assert b"\x1b_zmx;foreground" not in q.output, q.output[-300:]
q.type(b"\x1c")
assert q.wait_exit() == 0
PY
}

@test "events: connect marks the snapshot with APCs only when asked" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
import os
from ptyrun import Pty
start, end = b"\x1b_zmx;snapshot;start\x1b\\", b"\x1b_zmx;snapshot;end\x1b\\"
p = Pty([os.environ["ZMX"], "connect", "s1"])
p.type("printf '\\033]2;old\\007'; printf 'out-%s\\n' 1\r")
p.wait_output("out-1")
p.type(b"\x1c")
assert p.wait_exit() == 0
assert start not in p.output, p.output[-300:]

os.environ["ZMX_FOREGROUND_EVENTS"] = "1"
q = Pty([os.environ["ZMX"], "connect", "s1"])
q.wait_output(end.decode())
# The replayed title is between the two marks.
replay = q.output[q.output.index(start):q.output.index(end)]
assert b"\x1b]2;old\x07" in replay, replay[-300:]
q.type(b"\x1c")
assert q.wait_exit() == 0
PY
}

@test "events: program status reports become records, and the session answers the query" {
  query_py="$RT/query.py"
  printf '%s\n' \
    'import os, sys, termios, tty' \
    'old = termios.tcgetattr(0)' \
    'tty.setraw(0)' \
    'os.write(1, b"\x1b]7501;?\x07")' \
    'got = b""' \
    'while not got.endswith(b"\x07"): got += os.read(0, 1)' \
    'termios.tcsetattr(0, termios.TCSANOW, old)' \
    'print("reply=" + got[1:-1].decode())' >"$query_py"
  export query_py
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
import os
from v2client import Client
a = Client("s1")
a.attach()
a.wait_msg("state")
a.type("python3 " + os.environ["query_py"] + "\r")
a.wait_output("reply=]7501;?:states=idle,working,done,blocked,error")

a.type("printf '\\033]7501;state=working:app=make\\007\\033]7501;state=blocked:id=x:kind=question:msg=QWxsb3cgZWRpdD8=\\007'; printf 'st-%s\\n' 1\r")
a.wait_output("st-1")
a.wait(lambda: any(len(m["a"]["records"]) == 2 for m in a.messages("program_status")), what="two records")
records = a.messages("program_status")[-1]["a"]["records"]
assert records[0]["state"] == "working" and records[0]["app"] == "make", records
assert records[1] == {"id": "x", "state": "blocked", "kind": "question", "app": "make", "msg": "Allow edit?"}, records[1]

# A client that connects later gets the records.
b = Client("s1")
b.wait_msg("state")
assert len(b.wait_msg("program_status")["records"]) == 2

# The shell's exit removes them before the exit message.
a.type("exit\r")
a.wait_msg("exit")
kinds = [v["t"] for ch, kind, v in a.frames if ch == 1 and kind == 0]
last = len(kinds) - 1 - kinds[::-1].index("program_status")
assert a.messages("program_status")[-1]["a"]["records"] == []
assert last < kinds.index("exit"), kinds
PY
}

@test "tty_mode: a client that asks gets the pty's line modes when they change" {
  "$ZMX" session s1 -- /bin/sh
  python3 - <<'PY'
from v2client import Client
c = Client("s1")
c.attach(tty=True)
# The shell's own line editor is not line mode with echo off.
first = c.wait_msg("tty_mode")
assert not (first["canonical"] and not first["echo"]), first
c.type("stty -echo icanon; printf 'noecho-%s\\n' 1\r")
c.wait_output("noecho-1")
c.wait(lambda: {"canonical": True, "echo": False} in [v["a"] for v in c.messages("tty_mode")], 10, "password mode")
# The shell's line editor takes the tty back when it draws its prompt.
c.wait(lambda: not c.messages("tty_mode")[-1]["a"]["canonical"], 10, "raw again")
# A client that did not ask gets none.
d = Client("s1")
d.attach()
d.wait_msg("state")
d.type("printf 'quiet-%s\\n' 1\r")
d.wait_output("quiet-1")
assert d.messages("tty_mode") == []
PY
}
