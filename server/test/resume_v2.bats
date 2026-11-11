#!/usr/bin/env bats
# Resume after a short drop (design/003 §7, issue 0193): a client that lost
# its link asks for the output after its offset, and the server's events
# after its last seq. test/v2client.py is the client.

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
  for sock in "$MACTERM_RUNTIME_DIR"/*; do
    [[ -S "$sock" ]] || continue
    pid=$(python3 "$BATS_TEST_DIRNAME/v2client.py" pid "$(basename "$sock")" 2>/dev/null) || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  rm -rf "$RT"
}

@test "resume: a drop of a moment gets the missing bytes, no snapshot and no lost byte" {
  "$ZMX" session r1 -- /bin/cat
  python3 - <<'PY'
from v2client import Client
a = Client("r1"); a.attach(); a.wait_msg("state")
watch = Client("r1"); watch.attach(); watch.wait_msg("state")
a.type("one\n"); a.wait_output("one\r\none")
watch.wait_output("one\r\none")
epoch, offset = a.epoch(), a.offset()
assert offset == len(a.output) > 0, (offset, a.output)

# The link goes. Output goes on while the client is away.
a.close()
watch.type("two\n"); watch.wait_output("two\r\ntwo")
watch.type("three\n"); watch.wait_output("three\r\nthree")

b = Client("r1"); b.attach(resume=(epoch, offset))
res = b.wait_msg("resumed")
assert res["offset"] == offset, res
want = watch.output[offset:]
b.wait(lambda: len(b.output) >= len(want), what="the missing bytes")
assert b.output == want, (b.output, want)
assert not b.messages("snapshot.start"), b.messages()
# The whole stream has no gap: what A had, then what B got.
assert a.output + b.output == watch.output
assert b.offset() == watch.offset()

# And new output goes to B as it comes.
b.type("four\n"); b.wait_output("four\r\nfour")
PY
}

@test "resume: an offset that the session cannot serve gets a snapshot with its offset" {
  "$ZMX" session r2 -- /bin/sh -c 'head -c 700000 /dev/zero | tr "\\0" a; echo done-marker; exec cat'
  python3 - <<'PY'
from v2client import Client
first = Client("r2"); first.attach(); first.wait_msg("state")
first.wait_output("done-marker", timeout=60)
epoch = first.epoch()
end = first.offset()
assert end > 600000, end

def ask(resume):
    c = Client("r2"); c.attach(resume=resume)
    c.wait_msg("state")
    c.wait(lambda: c.messages("snapshot.start") or c.messages("resumed"), what="an answer")
    return c

# The ring lost offset 10: a snapshot, laid out at the end of the output.
c = ask((epoch, 10))
assert not c.messages("resumed")
assert c.messages("snapshot.start")[0]["a"]["offset"] == end

# Another epoch: a session that is not the one that the client left.
c = ask((epoch + 1, end))
assert not c.messages("resumed")
assert c.messages("snapshot.start")[0]["a"]["offset"] == end

# An offset ahead of the output cannot be true.
c = ask((epoch, end + 5))
assert not c.messages("resumed")

# No resume asked: a snapshot, as before.
c = ask(None)
assert c.messages("snapshot.start")[0]["a"]["scrollback"] is True

# The end of the output resumes with nothing to send.
c = ask((epoch, end))
assert c.messages("resumed")[0]["a"]["offset"] == end
assert not c.messages("snapshot.start")
PY
}

@test "resume: a snapshot says the offset that its screen shows, and the output after it counts from there" {
  "$ZMX" session r3 -- /bin/cat
  python3 - <<'PY'
from v2client import Client
a = Client("r3"); a.attach(); a.wait_msg("state")
a.type("x\n"); a.wait_output("x\r\nx")
late = Client("r3"); late.attach(); late.wait_msg("snapshot.end")
snap = late.messages("snapshot.start")[0]["a"]
assert snap["offset"] == a.offset(), (snap, a.offset())
late.type("y\n"); late.wait_output("y\r\ny")
assert late.offset() == a.offset() + len("y\r\ny\r\n"), (late.offset(), a.offset())
PY
}

@test "resume: the server sends the batches after the last seq, or says that it cannot" {
  "$ZMX" server
  python3 - <<'PY'
from v2client import ServerClient
c = ServerClient()
epoch = c.epoch()
for n in (1, 2, 3):
    c.call("session.create", id="e%d" % n, command=[b"/bin/sh", b"-c", b"exit %d" % n])
    c.wait_event("session.exit", lambda a, n=n: a["id"] == "e%d" % n)
seqs = [v["seq"] for v in c.control() if isinstance(v, dict) and "seq" in v]
assert seqs == [1, 2, 3], seqs

# A client that got the first batch and lost the link gets the other two.
d = ServerClient()
res = d.call("control.resume", epoch=epoch, seq=1)
assert res == {"replayed": True, "seq": 3}, res
assert [e["a"]["id"] for e in d.events("session.exit")] == ["e2", "e3"], d.events()
seqs = [v["seq"] for v in d.control() if isinstance(v, dict) and "seq" in v]
assert seqs == [2, 3], seqs

# A client with every batch gets none.
d = ServerClient()
assert d.call("control.resume", epoch=epoch, seq=3) == {"replayed": True, "seq": 3}
assert not d.events()

# Another epoch, or a seq from the future: no batch, and a full state to read.
d = ServerClient()
assert d.call("control.resume", epoch=epoch + 1, seq=1) == {"replayed": False, "seq": 3}
assert d.call("control.resume", epoch=epoch, seq=9) == {"replayed": False, "seq": 3}
assert not d.events()
assert set(d.sessions()) == {"e1", "e2", "e3"}
PY
}

@test "resume: a server that restarted has a new epoch, and the sessions keep their offsets" {
  "$ZMX" server
  python3 - <<'PY'
import os, signal, subprocess
from v2client import Client, ServerClient
c = ServerClient()
epoch = c.epoch()
c.call("session.create", id="k1", command=[b"/bin/cat"])
a = Client("k1"); a.attach(); a.wait_msg("state")
a.type("one\n"); a.wait_output("one\r\none")
sepoch, offset = a.epoch(), a.offset()
a.close()

# The server restarts; the session does not.
os.kill(c.peer_pid(), signal.SIGKILL)
c.wait_closed()
subprocess.check_call([os.environ["ZMX"], "server"])
d = ServerClient()
assert d.epoch() != epoch
res = d.call("control.resume", epoch=epoch, seq=0)
assert res["replayed"] is False, res
assert "k1" in d.sessions()

# The session is the same one, so its offset holds.
b = Client("k1"); b.attach(resume=(sepoch, offset))
assert b.wait_msg("resumed")["offset"] == offset
assert not b.messages("snapshot.start")
PY
}
