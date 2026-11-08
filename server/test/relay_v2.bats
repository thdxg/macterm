#!/usr/bin/env bats
# `zmx proxy` and the server's relay of channels (src/proxy.zig,
# src/relay.zig): every pane of a host on one stream, as the app reaches a
# host through ssh. test/v2client.py's RelayClient is the app.

load test_helper

setup_file() {
  export PYTHONPATH="$BATS_TEST_DIRNAME"
}

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
  rm -rf "$RT"
}

@test "proxy: starts the server, and two panes share one stream" {
  [ ! -S "$MACTERM_RUNTIME_DIR/.server" ]
  python3 - <<'PY'
from v2client import RelayClient
c = RelayClient()
c.wait(lambda: c.control, what="hello")
assert c.control[0]["role"] == "server", c.control[0]
assert c.call("ping") == {}
for id in ("a", "b"):
    c.call("session.create", id=id, command=[b"/bin/sh"])
a = c.open("a")
b = c.open("b")
assert a != b and 0 not in (a, b), (a, b)
c.wait_msg(a, "state")
c.type(a, "printf 'from-%s\\n' a1\r")
c.type(b, "printf 'from-%s\\n' b2\r")
c.wait_output(a, "from-a1")
c.wait_output(b, "from-b2")
assert b"from-b2" not in c.output[a] and b"from-a1" not in c.output[b]

# A closed channel gets nothing more; its session runs on.
assert c.call("channel.close", channel=b) == {}
assert c.request("channel.close", channel=b)["err"]["code"] == "not_found"
assert c.request("channel.open", session="nope")["err"]["code"] == "not_found"
seen = len(c.frames.get(b, []))
c.type(b, "printf 'gone-%s\\n' b3\r")
c.type(a, "printf 'still-%s\\n' a4\r")
c.wait_output(a, "still-a4")
assert len(c.frames.get(b, [])) == seen, c.frames[b][seen:]
assert c.call("session.info", id="b")["session"]["state"] == "running"

# Input that comes just before the close still reaches the session.
import os
from v2client import frame, pack, BYTES, MSG, CONTROL
path = os.path.join(os.environ["RT"], "closed")
d = c.call("session.create", id="d", command=[b"/bin/sh"])
dc = c.open("d")
c.wait_msg(dc, "state")
rid = c.next_id
c.next_id += 1
c.sock.sendall(frame(dc, BYTES, ("printf x > %s\r" % path).encode())
               + frame(CONTROL, MSG, pack({"id": rid, "m": "channel.close", "a": {"channel": dc}})))
c.wait(lambda: c.response(rid) is not None, what="the close")
c.wait(lambda: os.path.exists(path), what="the input before the close")

# The end of the stream ends the proxy, and the sessions stay.
c.close()
assert c.proc.returncode == 0, c.proc.returncode
again = RelayClient()
assert sorted(s["id"] for s in again.call("session.list")["sessions"]) == ["a", "b", "d"]
again.close()
PY
}

@test "relay: a flooding pane does not delay the other pane's keys or channel 0" {
  python3 - <<'PY'
import time
from v2client import RelayClient
c = RelayClient()
c.call("session.create", id="flood", command=[b"/bin/sh"])
c.call("session.create", id="quiet", command=[b"/bin/sh"])
f = c.open("flood")
q = c.open("quiet")
c.count_only.add(f)
c.wait_msg(q, "state")
c.type(q, "stty -echo; printf 'ready-%s\\n' 1\r")
c.wait_output(q, "ready-1")
c.type(f, "while :; do printf '%0200d\\n' 0; done\r")
c.wait(lambda: sum(n for k, n in c.frames.get(f, []) if k == "bytes") > 256 << 10, timeout=30, what="256 KiB of flood")

worst_ping = worst_key = 0.0
for i in range(10):
    start = time.time()
    rid = c.send_request("ping")
    c.wait(lambda: c.response(rid) is not None, what="ping")
    worst_ping = max(worst_ping, time.time() - start)

    start = time.time()
    c.type(q, "printf 'key-%%s\\n' %d\r" % i)
    c.wait_output(q, "key-%d" % i)
    worst_key = max(worst_key, time.time() - start)
print("worst ping %.3f s, worst key %.3f s" % (worst_ping, worst_key))
# Far under the 1 s after which the flood itself is skipped ahead.
assert worst_ping < 0.5, worst_ping
assert worst_key < 0.5, worst_key
c.type(f, "\x03")
c.close()
PY
}

@test "relay: a paused channel still sends the session's messages, and a resume sends a snapshot" {
  python3 - <<'PY'
from v2client import RelayClient
c = RelayClient()
c.call("session.create", id="p", command=[b"/bin/sh"])
ch = c.open("p")
c.wait_msg(ch, "state")
c.type(ch, "printf 'before-%s\\n' 1\r")
c.wait_output(ch, "before-1")

assert c.call("channel.pause", channel=ch) == {}
paused_at = len(c.frames[ch])
# Input still goes to the shell; its output does not come.
c.type(ch, "printf 'hidden-%s\\n' 2\r")
c.type(ch, "sleep 0.5; printf 'later-%s\\n' 3\r")
import time
end = time.time() + 1.5
while time.time() < end:
    c.pump()
after = c.frames[ch][paused_at:]
assert not [x for x in after if x[0] == "bytes"], after

# A resume sends the screen as it is now: a snapshot without scrollback.
snapshots = len(c.messages(ch, "snapshot.start"))
assert c.call("channel.resume", channel=ch) == {}
start = c.wait_msg(ch, "snapshot.start", count=snapshots + 1)
assert start == {"scrollback": False}, start
c.wait_msg(ch, "snapshot.end", count=snapshots + 1)
c.wait_output(ch, "later-3")
c.type(ch, "printf 'live-%s\\n' 4\r")
c.wait_output(ch, "live-4")

# Paused again, the shell's exit still comes on the channel and on channel 0.
c.call("channel.pause", channel=ch)
c.type(ch, "exit 4\r")
assert c.wait_msg(ch, "exit") == {"code": 4}
c.wait(lambda: [v for v in c.control if isinstance(v, dict) and "seq" in v
                and any(e["e"] == "session.exit" for e in v["ev"])], what="session.exit")
c.close()
PY
}

@test "relay: a channel that falls behind is skipped ahead to a snapshot" {
  python3 - <<'PY'
import time
from v2client import RelayClient
c = RelayClient()
c.call("session.create", id="s", command=[b"/bin/sh"])
ch = c.open("s")
c.count_only.add(ch)
c.wait_msg(ch, "state")
c.type(ch, "yes 0123456789012345678901234567890123456789012345678901234567890123456789 | head -c 2000000; printf 'done-%s\\n' 9\r")
# The app reads nothing for 4 s: output fills the buffers on the way, then
# waits in the server longer than 1 s.
time.sleep(4)
c.count_only.discard(ch)
c.wait(lambda: any(v.get("t") == "snapshot.start" and v["a"] == {"scrollback": False}
                   for v in c.messages(ch)), timeout=20, what="a snapshot after the skip")
c.wait_output(ch, "done-9", timeout=60)
# The output that waited was dropped, not sent late.
got = sum(n for k, n in c.frames[ch] if k == "bytes")
assert got < 2000000, got
c.close()
PY
}
