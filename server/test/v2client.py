"""A test client of the v2 session socket (src/session.zig).

Frames are `length u32` . `channel u32` . `kind u8` . body, little-endian
(src/protocol/frame.zig). Messages are MessagePack maps with string keys.
Only what the tests need: no floats, no ext types.
"""

import os
import select
import sys
import socket
import struct
import time

MSG, BYTES = 0, 1
CONTROL, PANE = 0, 1


# ── MessagePack ──────────────────────────────────────────────────────────────


def pack(v):
    if v is None:
        return b"\xc0"
    if v is True:
        return b"\xc3"
    if v is False:
        return b"\xc2"
    if isinstance(v, int):
        if 0 <= v < 0x80:
            return bytes([v])
        if -32 <= v < 0:
            return struct.pack("b", v)
        if 0 <= v <= 0xFFFFFFFF:
            return b"\xce" + struct.pack(">I", v)
        if 0 <= v:
            return b"\xcf" + struct.pack(">Q", v)
        return b"\xd3" + struct.pack(">q", v)
    if isinstance(v, str):
        b = v.encode()
        if len(b) < 32:
            return bytes([0xA0 | len(b)]) + b
        return b"\xda" + struct.pack(">H", len(b)) + b
    if isinstance(v, (bytes, bytearray)):
        return b"\xc5" + struct.pack(">H", len(v)) + bytes(v)
    if isinstance(v, (list, tuple)):
        return bytes([0x90 | len(v)]) + b"".join(pack(x) for x in v)
    if isinstance(v, dict):
        return bytes([0x80 | len(v)]) + b"".join(pack(k) + pack(x) for k, x in v.items())
    raise TypeError(v)


def unpack(b, i=0):
    """Returns (value, next index)."""
    t = b[i]
    i += 1
    if t < 0x80:
        return t, i
    if t >= 0xE0:
        return t - 0x100, i
    if 0x80 <= t <= 0x8F:
        return _map(b, i, t & 0x0F)
    if 0x90 <= t <= 0x9F:
        return _arr(b, i, t & 0x0F)
    if 0xA0 <= t <= 0xBF:
        n = t & 0x1F
        return b[i : i + n].decode(), i + n
    if t == 0xC0:
        return None, i
    if t == 0xC2:
        return False, i
    if t == 0xC3:
        return True, i
    sizes = {0xC4: 1, 0xC5: 2, 0xC6: 4, 0xD9: 1, 0xDA: 2, 0xDB: 4}
    if t in sizes:
        k = sizes[t]
        n = int.from_bytes(b[i : i + k], "big")
        i += k
        raw = b[i : i + n]
        return (raw if t <= 0xC6 else raw.decode()), i + n
    ints = {0xCC: ">B", 0xCD: ">H", 0xCE: ">I", 0xCF: ">Q", 0xD0: ">b", 0xD1: ">h", 0xD2: ">i", 0xD3: ">q"}
    if t in ints:
        f = ints[t]
        k = struct.calcsize(f)
        return struct.unpack(f, b[i : i + k])[0], i + k
    if t in (0xDC, 0xDE):
        n = struct.unpack(">H", b[i : i + 2])[0]
        return (_arr if t == 0xDC else _map)(b, i + 2, n)
    raise ValueError("type byte %#x" % t)


def _map(b, i, n):
    d = {}
    for _ in range(n):
        k, i = unpack(b, i)
        d[k], i = unpack(b, i)
    return d, i


def _arr(b, i, n):
    a = []
    for _ in range(n):
        x, i = unpack(b, i)
        a.append(x)
    return a, i


def frame(channel, kind, body):
    return struct.pack("<IIB", len(body), channel, kind) + body


# ── Client ───────────────────────────────────────────────────────────────────


def runtime_dir():
    return os.environ["MACTERM_RUNTIME_DIR"]


def hello(level=1, min_level=1, role="gui"):
    return {"level": level, "min_level": min_level, "build": "test", "role": role, "epoch": 1, "caps": []}


class Client:
    def __init__(self, name, greet=True, level=1, min_level=1):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(os.path.join(runtime_dir(), name))
        self.buf = b""
        self.closed = False
        # Every frame in order: (channel, kind, body or decoded message).
        self.frames = []
        self.output = b""
        if greet:
            self.send_msg(CONTROL, hello(level, min_level))

    def send(self, channel, kind, body):
        self.sock.sendall(frame(channel, kind, body))

    def send_msg(self, channel, value):
        self.send(channel, MSG, pack(value))

    def pane(self, t, **a):
        self.send_msg(PANE, {"t": t, "a": a})

    def attach(self, cols=80, rows=24, foreground=False, resume=None, tty=False):
        """`resume` is (epoch, offset): ask to resume (design/003 section 7)."""
        extra = {} if resume is None else {"resume_epoch": resume[0], "resume_offset": resume[1]}
        self.pane("attach", cols=cols, rows=rows, foreground=foreground, tty=tty, **extra)

    def epoch(self):
        """The `epoch` of the peer's hello."""
        self.wait(lambda: self.control(), what="the peer's hello")
        return self.control()[0]["epoch"]

    def offset(self):
        """The offset after the last output byte that this client got: the
        offset of its last snapshot (or `resumed`, or 0), plus the output
        bytes after it. A snapshot's own bytes do not count."""
        offset, snap = 0, False
        for ch, kind, v in self.frames:
            if ch != PANE:
                continue
            if kind == MSG:
                t = v.get("t")
                if t == "snapshot.start":
                    snap, offset = True, v["a"]["offset"]
                elif t == "snapshot.end":
                    snap = False
                elif t == "resumed":
                    offset = v["a"]["offset"]
            elif not snap:
                offset += len(v)
        return offset

    def type(self, text):
        self.send(PANE, BYTES, text.encode() if isinstance(text, str) else text)

    def _read(self, timeout):
        r, _, _ = select.select([self.sock], [], [], timeout)
        if not r:
            return
        data = self.sock.recv(65536)
        if not data:
            self.closed = True
            return
        self.buf += data
        while len(self.buf) >= 9:
            n, ch, kind = struct.unpack("<IIB", self.buf[:9])
            if len(self.buf) < 9 + n:
                break
            body = self.buf[9 : 9 + n]
            self.buf = self.buf[9 + n :]
            if kind == MSG:
                value, _ = unpack(body)
                self.frames.append((ch, kind, value))
            else:
                self.frames.append((ch, kind, body))
                self.output += body

    def wait(self, pred, timeout=10, what="condition"):
        deadline = time.time() + timeout
        while not pred():
            if self.closed:
                raise AssertionError("connection closed before %s; frames=%r" % (what, self.frames[-5:]))
            if time.time() > deadline:
                raise AssertionError("timed out waiting for %s; output tail=%r" % (what, self.output[-300:]))
            self._read(0.05)

    def messages(self, t=None):
        out = []
        for ch, kind, v in self.frames:
            if ch == PANE and kind == MSG and (t is None or v.get("t") == t):
                out.append(v)
        return out

    def wait_msg(self, t, count=1, timeout=10):
        self.wait(lambda: len(self.messages(t)) >= count, timeout, "message %s" % t)
        return self.messages(t)[count - 1].get("a", {})

    def wait_output(self, text, timeout=10):
        b = text.encode()
        self.wait(lambda: b in self.output, timeout, "output %r" % text)

    def wait_closed(self, timeout=10):
        deadline = time.time() + timeout
        while not self.closed:
            if time.time() > deadline:
                raise AssertionError("connection still open")
            self._read(0.05)

    def control(self):
        return [v for ch, kind, v in self.frames if ch == CONTROL]

    def close(self):
        self.sock.close()


class ServerClient(Client):
    """A GUI on the server's socket (src/server.zig): requests and events on
    channel 0."""

    def __init__(self, role="gui", build="test", level=1, min_level=1):
        self.role, self.build = role, build
        self.next_id = 1
        super().__init__(".server", greet=False)
        self.send_msg(CONTROL, dict(hello(level, min_level, role), build=build))

    def request(self, method, timeout=10, **args):
        rid = self.next_id
        self.next_id += 1
        self.send_msg(CONTROL, {"id": rid, "m": method, "a": args})
        found = lambda: [v for v in self.control() if isinstance(v, dict) and v.get("re") == rid]
        self.wait(lambda: found(), timeout, "a response to %s" % method)
        return found()[0]

    def call(self, method, timeout=10, **args):
        """The result, or an AssertionError that holds the error."""
        res = self.request(method, timeout, **args)
        assert "ok" in res, "%s failed: %r" % (method, res)
        return res["ok"]

    def events(self, e=None):
        out = []
        for v in self.control():
            if isinstance(v, dict) and "seq" in v:
                out += [x for x in v["ev"] if e is None or x["e"] == e]
        return out

    def wait_event(self, e, pred=lambda a: True, timeout=10):
        match = lambda: [x["a"] for x in self.events(e) if pred(x["a"])]
        self.wait(lambda: match(), timeout, "event %s" % e)
        return match()[0]

    def sessions(self):
        return {x["id"]: x for x in self.call("session.list")["sessions"]}

    def peer_pid(self):
        if sys.platform == "darwin":
            # SOL_LOCAL, LOCAL_PEERPID
            return struct.unpack("i", self.sock.getsockopt(0, 2, 4))[0]
        return struct.unpack("3i", self.sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0]


class RelayClient:
    """A GUI that reaches the server through `zmx proxy` on its stdio, as the
    app reaches a host's server through ssh. Each pane is a channel of the
    one stream (src/relay.zig)."""

    def __init__(self, zmx=None, argv=None, skip_to=None):
        """`argv` runs in place of `<zmx> proxy`: an ssh command that execs
        the proxy on a host (test/host_install.bats). The bytes up to and
        with `skip_to` are dropped, as the app drops the text before the
        line of host/attach.sh."""
        import subprocess

        ours, theirs = socket.socketpair()
        # Small buffers, as a pipe to ssh: a reader that stops makes the
        # server's queues grow soon.
        theirs.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4096)
        ours.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        self.proc = subprocess.Popen(argv or [zmx or os.environ["ZMX"], "proxy"], stdin=theirs, stdout=theirs)
        theirs.close()
        self.sock = ours
        self.buf = bytearray()
        self.closed = False
        self.skip_to = skip_to
        self.next_id = 1
        # Channel 0's messages, in order.
        self.control = []
        # For each channel: its frames in order, as ("msg", value) or
        # ("bytes", length), and its output.
        self.frames = {}
        self.output = {}
        # The channels whose output is only counted, not kept.
        self.count_only = set()
        self.send_msg(CONTROL, hello())

    def send(self, channel, kind, body):
        self.sock.sendall(frame(channel, kind, body))

    def send_msg(self, channel, value):
        self.send(channel, MSG, pack(value))

    def pane(self, channel, t, **a):
        self.send_msg(channel, {"t": t, "a": a})

    def type(self, channel, text):
        self.send(channel, BYTES, text.encode())

    def pump(self, timeout=0.05):
        r, _, _ = select.select([self.sock], [], [], timeout)
        if not r:
            return
        data = self.sock.recv(1 << 20)
        if not data:
            self.closed = True
            return
        self.buf += data
        if self.skip_to is not None:
            at = self.buf.find(self.skip_to)
            if at < 0:
                return
            del self.buf[: at + len(self.skip_to)]
            self.skip_to = None
        i = 0
        while len(self.buf) - i >= 9:
            n, ch, kind = struct.unpack_from("<IIB", self.buf, i)
            if len(self.buf) - i < 9 + n:
                break
            body = bytes(self.buf[i + 9 : i + 9 + n])
            i += 9 + n
            if ch == CONTROL:
                self.control.append(unpack(body)[0])
            elif kind == MSG:
                self.frames.setdefault(ch, []).append(("msg", unpack(body)[0]))
            else:
                self.frames.setdefault(ch, []).append(("bytes", len(body)))
                if ch not in self.count_only:
                    self.output[ch] = self.output.get(ch, b"") + body
        del self.buf[:i]

    def wait(self, pred, timeout=10, what="condition"):
        deadline = time.time() + timeout
        while not pred():
            if self.closed:
                raise AssertionError("stream closed before %s" % what)
            if time.time() > deadline:
                raise AssertionError("timed out waiting for %s" % what)
            self.pump()

    def send_request(self, method, **args):
        rid = self.next_id
        self.next_id += 1
        self.send_msg(CONTROL, {"id": rid, "m": method, "a": args})
        return rid

    def response(self, rid):
        found = [v for v in self.control if isinstance(v, dict) and v.get("re") == rid]
        return found[0] if found else None

    def request(self, method, timeout=10, **args):
        rid = self.send_request(method, **args)
        self.wait(lambda: self.response(rid) is not None, timeout, "a response to %s" % method)
        return self.response(rid)

    def call(self, method, timeout=10, **args):
        res = self.request(method, timeout, **args)
        assert "ok" in res, "%s failed: %r" % (method, res)
        return res["ok"]

    def messages(self, channel, t=None):
        return [v for kind, v in self.frames.get(channel, []) if kind == "msg" and (t is None or v.get("t") == t)]

    def wait_msg(self, channel, t, count=1, timeout=10):
        self.wait(lambda: len(self.messages(channel, t)) >= count, timeout, "message %s on %d" % (t, channel))
        return self.messages(channel, t)[count - 1].get("a", {})

    def wait_output(self, channel, text, timeout=10):
        b = text.encode()
        self.wait(lambda: b in self.output.get(channel, b""), timeout, "output %r on %d" % (text, channel))

    def open(self, session, cols=80, rows=24):
        ch = self.call("channel.open", session=session)["channel"]
        self.pane(ch, "attach", cols=cols, rows=rows)
        return ch

    def close(self):
        self.sock.close()
        self.proc.wait(5)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def wait_dead(pid, timeout=5):
    deadline = time.time() + timeout
    while alive(pid):
        assert time.time() < deadline, "process %d still runs" % pid
        time.sleep(0.05)


if __name__ == "__main__":
    # `v2client.py pid <name>`: the session process's pid, for a teardown.
    if sys.argv[1] == "server-pid":
        print(ServerClient().peer_pid())
    elif sys.argv[1] == "pid":
        c = Client(sys.argv[2])
        print(c.wait_msg("state", timeout=5)["pid"])
