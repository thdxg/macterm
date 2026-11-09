#!/usr/bin/env python3
"""Session-layer benchmark.

Measures what the session layer (zmx, and ssh for remote panes) adds to
typing, reattach, memory and idle cost, for v1's and v2's local panes side by
side. It runs no app: a pty driver plays the part of the terminal, so it runs
on any CI runner, macOS or Linux.

Local panes (one zmx binary has both):

  v1         `zmx attach <s> <command>`: a v1 session daemon for each pane.
  v2         `zmx connect <s> -- <command>`: a v2 session, made through the
             server (`macterm attach` later, design/007).

Arms (each is a program on a pty that this script drives):

  bare       /bin/cat on a pty in line mode: kernel echo only. The floor.
  v1, v2     /bin/cat in a local pane.
  ssh        `ssh -tt <host> /bin/cat`. The floor for a remote pane.
  ssh-zmx    `ssh -tt <host> zmx attach <s> /bin/cat`. A remote pane of v1.

Echo latency: write one key, time until the echo arrives, for --keys keys.
Remote pane open: time from the start of `ssh … zmx attach` to the first
echo after the session prints its ready marker. v1 makes a new ssh login for
each remote pane.
Reattach: fill a session with --reattach-lines lines of 200 columns, detach,
then time a new client until the echo of a marker line that is sent after the
client takes the terminal. The echo comes after the replay.
Idle (macOS): open --idle-panes panes of /bin/cat in each layer, then read the
phys_footprint and the wakeups of the session side (v1: the daemons; v2: the
server and the sessions) and of the clients. The programs in the panes are
not counted: they are the same in both layers.

Every v1/v2 pair runs in one run on one runner, alternated: the echo keys go
in rounds to v1 and v2 in turn, the reattaches alternate, and the idle panes
of both layers are measured in the same window. A shared runner changes
speed over minutes, so a pair is compared only within one run.

Load decides latency on a shared runner, so each measurement first waits for
the 1-minute load average to drop below --max-load and records the load.

Subcommands:
  run     measure every arm, write a results JSON
  report  render one or more results JSONs as markdown
"""

import argparse
import fcntl
import json
import os
import select
import shlex
import shutil
import signal
import socket
import statistics
import struct
import subprocess
import sys
import tempfile
import termios
import time
import uuid

from _harness import phys_footprint, runner_info, wait_for_load, wakeups

COLUMNS = 200
ROWS = 50
DETACH_KEY = b"\x1c"  # ctrl+\: zmx detaches the current client.
LAYERS = ("v1", "v2")


class BenchError(Exception):
    pass


# ── The pty driver ───────────────────────────────────────────────────────


class PtyProgram:
    """One program on a new pty, as a terminal would run it."""

    def __init__(self, argv, env=None):
        self.argv = argv
        self.started = time.monotonic()
        pid, fd = os.forkpty()
        if pid == 0:
            try:
                winsize = struct.pack("HHHH", ROWS, COLUMNS, 0, 0)
                fcntl.ioctl(0, termios.TIOCSWINSZ, winsize)
                os.execvpe(argv[0], argv, env or os.environ)
            finally:
                os._exit(127)
        self.pid = pid
        self.fd = fd
        self.output = bytearray()

    def write(self, data):
        os.write(self.fd, data)

    def read_available(self, timeout):
        """Read what arrives within timeout. Returns the new bytes."""
        ready, _, _ = select.select([self.fd], [], [], timeout)
        if not ready:
            return b""
        try:
            data = os.read(self.fd, 65536)
        except OSError:  # EIO: the program closed the pty.
            raise BenchError(f"{self.argv[0]} closed its terminal: {self.tail()}")
        if not data:
            raise BenchError(f"{self.argv[0]} closed its terminal: {self.tail()}")
        self.output += data
        return data

    def read_until(self, needle, timeout, since=None):
        """Read until needle is in the output after offset `since`. Returns
        the time it arrived."""
        position = len(self.output) if since is None else since
        deadline = time.monotonic() + timeout
        while self.output.find(needle, position) < 0:
            # Search only the new bytes next time. A needle can arrive split
            # across reads, so look back by its length less one.
            position = max(position, len(self.output) - len(needle) + 1)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BenchError(
                    f"timed out after {timeout:.0f}s waiting for {needle!r} from "
                    f"{self.argv[0]}: {self.tail()}"
                )
            self.read_available(remaining)
        return time.monotonic()

    def drain(self, quiet=0.2, limit=5.0):
        """Read until the program is quiet for `quiet` seconds."""
        deadline = time.monotonic() + limit
        while time.monotonic() < deadline:
            if not self.read_available(quiet):
                return

    def is_raw(self):
        """Whether the program has taken the terminal (echo and line mode
        off). Before that, the pty's own line discipline echoes, and a key
        written then would time the kernel and not the program."""
        lflag = termios.tcgetattr(self.fd)[3]
        return not lflag & (termios.ECHO | termios.ICANON)

    def wait_raw(self, timeout):
        deadline = time.monotonic() + timeout
        while not self.is_raw():
            if time.monotonic() >= deadline:
                raise BenchError(f"{self.argv[0]} did not take the terminal: {self.tail()}")
            # Keep the pty drained, so a client that writes first never blocks.
            self.read_available(0.001)
        return time.monotonic()

    def wait_exit(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            pid, _ = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.pid = None
                return True
            try:
                self.read_available(0.05)
            except BenchError:
                pass
        return False

    def close(self):
        if self.pid is not None:
            try:
                os.kill(self.pid, signal.SIGKILL)
                os.waitpid(self.pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
            self.pid = None
        try:
            os.close(self.fd)
        except OSError:
            pass

    def tail(self):
        return bytes(self.output[-300:]).decode("utf-8", "replace")


def echo_latencies(program, keys, line_length=40):
    """Write `keys` keys one at a time; return each echo time in ms. Every
    line_length keys a newline ends the line (a canonical pty holds at most
    MAX_CANON bytes), and the line's own output is drained untimed."""
    letters = b"abcdefghijklmnopqrstuvwxyz"
    samples = []
    for i in range(keys):
        key = letters[i % len(letters):i % len(letters) + 1]
        offset = len(program.output)
        start = time.monotonic()
        program.write(key)
        end = program.read_until(key, timeout=10, since=offset)
        samples.append((end - start) * 1000)
        if (i + 1) % line_length == 0:
            program.write(b"\n")
            program.drain()
    program.write(b"\n")
    program.drain()
    return samples


def summarize(samples):
    ordered = sorted(samples)

    def pct(p):
        index = min(len(ordered) - 1, max(0, round(p / 100 * len(ordered)) - 1))
        return round(ordered[index], 3)

    return {
        "n": len(ordered),
        "p50_ms": round(statistics.median(ordered), 3),
        "p95_ms": pct(95),
        "p99_ms": pct(99),
        "max_ms": round(ordered[-1], 3),
    }


def wait_ready(program, takes_terminal=True, marker=None, timeout=30):
    """Wait until the program has the terminal and its far end echoes. A
    program that does not take the terminal (bare cat) echoes through the
    pty's own line discipline. With a marker, wait for the session to print
    it first: an ssh client takes the terminal before the remote side runs
    zmx, and the remote pty would echo a key before zmx has it."""
    if takes_terminal:
        program.wait_raw(timeout)
    if marker:
        program.read_until(marker.encode(), timeout, since=0)
    offset = len(program.output)
    program.write(b"@")
    first_echo = program.read_until(b"@", timeout, since=offset)
    program.write(b"\n")
    program.drain()
    return first_echo


# ── Arms ─────────────────────────────────────────────────────────────────


def alternated(index):
    """The order of the two layers in round `index`: v1 first, then v2 first."""
    return LAYERS if index % 2 == 0 else LAYERS[::-1]


class Bench:
    def __init__(self, args):
        self.args = args
        self.nonce = uuid.uuid4().hex[:8]
        # /tmp, not $TMPDIR: zmx socket paths must fit sun_path.
        self.zmx_dir = tempfile.mkdtemp(prefix="macterm-session-bench-", dir="/tmp")
        # v2's server and sessions live in the runtime directory. Without
        # this, they would be the user's own (TMPDIR/macterm).
        self.runtime_dir = os.path.join(self.zmx_dir, "run")
        self.env = dict(
            os.environ, ZMX_DIR=self.zmx_dir, MACTERM_RUNTIME_DIR=self.runtime_dir,
            TERM="xterm-256color",
        )
        self.local_sessions = []
        self.remote_sessions = []

    def session(self, label, remote=False):
        name = f"bench-{label}-{self.nonce}"
        (self.remote_sessions if remote else self.local_sessions).append(name)
        return name

    def ready_cat(self):
        """The session's program: print a ready marker, then cat. Returns
        the command and the marker. The marker is two words in the script, so
        the echo of the command line never matches it."""
        marker = f"ready-{self.nonce}"
        return ["/bin/sh", "-c", f"printf '%s-%s\\n' ready {self.nonce}; exec /bin/cat"], marker

    def zmx_attach(self, name, command=None):
        return [self.args.zmx, "attach", name, *(command or [])]

    def pane(self, layer, name, command=None):
        """The client of a local pane. With a command, it makes the session
        when none has the name; without, it attaches to the session."""
        if layer == "v1":
            return self.zmx_attach(name, command)
        return [self.args.zmx, "connect", name, *(["--", *command] if command else [])]

    def ssh(self, remote_command):
        return [
            "ssh", "-tt", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
            self.args.ssh_host, remote_command,
        ]

    def remote_zmx(self, *words):
        return " ".join(
            [f"ZMX_DIR={shlex.quote(self.zmx_dir)}", shlex.quote(self.args.zmx)]
            + [shlex.quote(word) for word in words]
        )

    def gate(self):
        return wait_for_load(self.args.max_load, self.args.load_timeout)

    def echo_arm(self, name, argv, takes_terminal=True, marker=None):
        gate = self.gate()
        print(f"{name}: load {gate['load']}, {self.args.keys} keys", flush=True)
        program = PtyProgram(argv, self.env)
        try:
            wait_ready(program, takes_terminal, marker)
            result = summarize(echo_latencies(program, self.args.keys))
        finally:
            program.close()
        result["load_gate"] = gate
        print(f"  {result}", flush=True)
        return result

    def echo_pair(self):
        """Echo latency of a v1 and a v2 pane, both open, the keys in rounds
        that alternate between them."""
        rounds = self.args.rounds
        per_round = max(1, self.args.keys // rounds)
        gate = self.gate()
        print(f"echo v1/v2: load {gate['load']}, {rounds} rounds of {per_round} keys", flush=True)
        command, marker = self.ready_cat()
        programs, samples = {}, {layer: [] for layer in LAYERS}
        try:
            for layer in LAYERS:
                programs[layer] = PtyProgram(
                    self.pane(layer, self.session(f"echo-{layer}"), command), self.env
                )
                wait_ready(programs[layer], marker=marker)
            for i in range(rounds):
                for layer in alternated(i):
                    samples[layer] += echo_latencies(programs[layer], per_round)
        finally:
            for program in programs.values():
                program.close()
        results = {}
        for layer in LAYERS:
            results[layer] = summarize(samples[layer])
            results[layer]["load_gate"] = gate
            print(f"  {layer}: {results[layer]}", flush=True)
        return results

    def remote_pane_open(self):
        """Time a new remote pane: ssh login, then zmx attach, until the
        first echo."""
        gate = self.gate()
        print(f"remote-pane-open: load {gate['load']}, {self.args.panes} panes", flush=True)
        samples = []
        for i in range(self.args.panes):
            name = self.session(f"pane{i}", remote=True)
            command, marker = self.ready_cat()
            program = PtyProgram(self.ssh(self.remote_zmx("attach", name, *command)), self.env)
            try:
                first_echo = wait_ready(program, marker=marker)
                samples.append((first_echo - program.started) * 1000)
            finally:
                program.close()
        result = summarize(samples)
        result["load_gate"] = gate
        print(f"  {result}", flush=True)
        return result

    def fill(self, layer):
        """Make a session of the layer with --reattach-lines lines of output,
        and detach from it. Returns its name."""
        lines = self.args.reattach_lines
        name = self.session(f"reattach-{layer}")
        marker = f"fill-done-{self.nonce}"
        # 6 characters of line number and 193 dots: 199 columns, so that no
        # line wraps on the 200-column terminal.
        script = (
            f'i=0; while [ $i -lt {lines} ]; do printf "%05d %s\\n" $i "{"." * 193}"; '
            f"i=$((i+1)); done; printf '%s\\n' {marker}; stty -echo; "
            "exec awk '{print \"got-\" $0; fflush()}'"
        )
        fill = PtyProgram(self.pane(layer, name, ["/bin/sh", "-c", script]), self.env)
        try:
            fill.wait_raw(30)
            fill.read_until(marker.encode(), timeout=120, since=0)
            fill.write(DETACH_KEY)
            if not fill.wait_exit(10):
                raise BenchError(f"the {layer} client did not detach")
        finally:
            fill.close()
        return name

    def reattach_pair(self):
        names = {layer: self.fill(layer) for layer in LAYERS}
        gate = self.gate()
        print(f"reattach v1/v2: load {gate['load']}, {self.args.reattach_lines} lines, "
              f"{self.args.attaches} attaches each", flush=True)
        samples = {layer: [] for layer in LAYERS}
        replay_bytes = {layer: [] for layer in LAYERS}
        for i in range(self.args.attaches):
            for layer in alternated(i):
                token = f"m{self.nonce}{layer}r{i}x"
                program = PtyProgram(self.pane(layer, names[layer]), self.env)
                try:
                    program.wait_raw(30)
                    program.write(f"{token}\n".encode())
                    end = program.read_until(f"got-{token}".encode(), timeout=60, since=0)
                    samples[layer].append((end - program.started) * 1000)
                    replay_bytes[layer].append(len(program.output))
                    program.write(DETACH_KEY)
                    program.wait_exit(10)
                finally:
                    program.close()
        results = {}
        for layer in LAYERS:
            result = summarize(samples[layer])
            result["lines"] = self.args.reattach_lines
            result["columns"] = COLUMNS
            result["replay_bytes"] = int(statistics.median(replay_bytes[layer]))
            result["load_gate"] = gate
            results[layer] = result
            print(f"  {layer}: {result}", flush=True)
        return results

    # ── Idle cost (macOS) ──

    def server_pid(self):
        """The pid of v2's server, from its socket (LOCAL_PEERPID). Its argv
        is the client's that started it, so `ps` cannot tell it from one."""
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            sock.connect(os.path.join(self.runtime_dir, ".server"))
            return struct.unpack("i", sock.getsockopt(0, 2, 4))[0]  # SOL_LOCAL, LOCAL_PEERPID
        except OSError as exc:
            raise BenchError(f"no v2 server in {self.runtime_dir}: {exc}")
        finally:
            sock.close()

    def session_pids(self, entry, names):
        """The pids of the session processes (`zmx <entry> <name> …`) of
        these names: v1's `__daemon`, v2's `__session`."""
        listing = subprocess.run(
            ["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True
        ).stdout
        pids = []
        for line in listing.splitlines():
            pid, _, command = line.strip().partition(" ")
            if not command.startswith(self.args.zmx + " "):
                continue
            words = command[len(self.args.zmx):].split()
            if len(words) >= 2 and words[0] == entry and words[1] in names:
                pids.append(int(pid))
        if len(pids) != len(names):
            raise BenchError(f"found {len(pids)} {entry} processes for {len(names)} sessions")
        return pids

    def idle_groups(self, clients, names):
        """The pids to measure: for each layer, its session side and its
        clients. The programs in the panes are left out."""
        return {
            ("v1", "session"): self.session_pids("__daemon", names["v1"]),
            ("v2", "session"): [self.server_pid(), *self.session_pids("__session", names["v2"])],
            ("v1", "client"): [program.pid for program in clients["v1"]],
            ("v2", "client"): [program.pid for program in clients["v2"]],
        }

    def idle_sample(self, groups):
        """The median footprint of each group over three reads, then its
        wakeups over --idle-seconds."""
        footprints = {group: [] for group in groups}
        for _ in range(3):
            for group, pids in groups.items():
                footprints[group].append(sum(phys_footprint(pid) or 0 for pid in pids))
            time.sleep(1)

        def count(pids):
            counts = [wakeups(pid) for pid in pids]
            if None in counts:
                raise BenchError("a session process ended during the idle measurement")
            return sum(counts)

        before = {group: count(pids) for group, pids in groups.items()}
        start = time.monotonic()
        time.sleep(self.args.idle_seconds)
        elapsed = time.monotonic() - start
        after = {group: count(pids) for group, pids in groups.items()}

        result = {}
        for (layer, side), pids in groups.items():
            data = result.setdefault(layer, {})
            data[f"{side}_mb"] = round(statistics.median(footprints[(layer, side)]) / 1048576, 2)
            data[f"{side}_wakeups_per_s"] = round(
                (after[(layer, side)] - before[(layer, side)]) / elapsed, 2
            )
            data[f"{side}_processes"] = len(pids)
        return result

    def idle_pair(self):
        """Footprint and wakeups of idle panes, v1 and v2 open at once, at
        each size of --idle-panes."""
        sizes = sorted(set(self.args.idle_panes))
        gate = self.gate()
        print(f"idle v1/v2: load {gate['load']}, {sizes} panes, "
              f"{self.args.idle_seconds}s windows", flush=True)
        command, marker = self.ready_cat()
        clients = {layer: [] for layer in LAYERS}
        names = {layer: [] for layer in LAYERS}
        result = {"seconds": self.args.idle_seconds, "panes": {}, "load_gate": gate}
        try:
            for size in sizes:
                for layer in LAYERS:
                    while len(clients[layer]) < size:
                        name = self.session(f"idle-{layer}-{len(names[layer])}")
                        names[layer].append(name)
                        clients[layer].append(PtyProgram(self.pane(layer, name, command), self.env))
                        wait_ready(clients[layer][-1], marker=marker)
                time.sleep(self.args.idle_settle)
                result["panes"][str(size)] = self.idle_sample(self.idle_groups(clients, names))
                print(f"  {size} panes: {result['panes'][str(size)]}", flush=True)
        finally:
            for program in clients["v1"] + clients["v2"]:
                program.close()
        return result

    def cleanup(self):
        # A session with no client keeps running and drops terminal replies,
        # so every session that this run made is ended, local and remote.
        if self.local_sessions:
            subprocess.run(
                [self.args.zmx, "kill", *self.local_sessions, "--force"],
                env=self.env, capture_output=True, timeout=30, check=False,
            )
            # `zmx kill` ends v1's sessions. v2's sessions and the server
            # carry a session name of this run in their argv: end them.
            listing = subprocess.run(
                ["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=False
            ).stdout
            ours = set(self.local_sessions)
            for line in listing.splitlines():
                pid, _, command = line.strip().partition(" ")
                if command.startswith(self.args.zmx + " ") and ours & set(command.split()):
                    try:
                        os.kill(int(pid), signal.SIGTERM)
                    except ProcessLookupError:
                        pass
        if self.remote_sessions:
            subprocess.run(
                ["ssh", "-o", "BatchMode=yes", self.args.ssh_host,
                 self.remote_zmx("kill", *self.remote_sessions, "--force")],
                capture_output=True, timeout=60, check=False,
            )
        shutil.rmtree(self.zmx_dir, ignore_errors=True)


def ssh_version():
    result = subprocess.run(["ssh", "-V"], capture_output=True, text=True, check=False)
    return (result.stderr or result.stdout).strip() or None


def cmd_run(args):
    args.zmx = os.path.abspath(args.zmx)
    if args.max_load is None:
        args.max_load = max(1.0, os.cpu_count() / 2)
    bench = Bench(args)
    arms = {}
    try:
        arms["bare"] = bench.echo_arm("bare", ["/bin/cat"], takes_terminal=False)
        arms.update(bench.echo_pair())
        if args.ssh_host:
            command, marker = bench.ready_cat()
            arms["ssh"] = bench.echo_arm(
                "ssh", bench.ssh(" ".join(shlex.quote(word) for word in command)), marker=marker
            )
            arms["ssh-zmx"] = bench.echo_arm(
                "ssh-zmx",
                bench.ssh(bench.remote_zmx("attach", bench.session("echo", remote=True), *command)),
                marker=marker,
            )
            arms["remote-pane-open"] = bench.remote_pane_open()
        for layer, result in bench.reattach_pair().items():
            arms[f"reattach-{layer}"] = result
        # phys_footprint and the wakeup counts are read through libproc.
        if sys.platform == "darwin":
            arms["idle"] = bench.idle_pair()
    except BenchError as exc:
        sys.exit(f"error: {exc}")
    finally:
        bench.cleanup()

    version = subprocess.run([args.zmx, "version"], capture_output=True, text=True, check=False)
    payload = {
        "schema": 2,
        "commit": os.environ.get("GITHUB_SHA") or subprocess.run(
            ["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=False
        ).stdout.strip() or "unknown",
        "runner": runner_info(),
        "zmx": version.stdout.split("\n", 1)[0].split()[-1] if version.stdout else None,
        "network": args.network,
        # OpenSSH 9.5 and later delays keystrokes (ObscureKeystrokeTiming), so
        # the ssh arms depend on the client's version.
        "ssh": ssh_version() if args.ssh_host else None,
        "arms": arms,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(payload, f, indent=2)
    print(f"wrote {args.out}")


ARM_LABELS = {
    "bare": "Echo, bare pty (floor)",
    "v1": "Echo, local pane, v1",
    "v2": "Echo, local pane, v2",
    "ssh": "Echo, ssh (floor)",
    "ssh-zmx": "Echo, remote pane (ssh + zmx)",
    "remote-pane-open": "New remote pane, to first echo",
    "reattach-v1": "Reattach, v1, to first echo after replay",
    "reattach-v2": "Reattach, v2, to first echo after replay",
}


def ratio(v1, v2):
    return f"{v2 / v1:.2f}" if v1 else "—"


def pair_rows(arms):
    """The v1/v2 pairs of local panes: (measurement, v1, v2, format)."""
    rows = []
    if "v1" in arms and "v2" in arms:
        rows += [
            ("Echo p50 (ms)", arms["v1"]["p50_ms"], arms["v2"]["p50_ms"], "{:.3f}"),
            ("Echo p95 (ms)", arms["v1"]["p95_ms"], arms["v2"]["p95_ms"], "{:.3f}"),
        ]
    if "reattach-v1" in arms and "reattach-v2" in arms:
        rows.append(("Reattach p50 (ms)", arms["reattach-v1"]["p50_ms"],
                     arms["reattach-v2"]["p50_ms"], "{:.1f}"))
    for size, layers in (arms.get("idle") or {}).get("panes", {}).items():
        def total(layer, key):
            return layers[layer][f"session_{key}"] + layers[layer][f"client_{key}"]
        rows += [
            (f"Memory, {size} idle panes (MB)", total("v1", "mb"), total("v2", "mb"), "{:.1f}"),
            (f"Wakeups/s, {size} idle panes", total("v1", "wakeups_per_s"),
             total("v2", "wakeups_per_s"), "{:.1f}"),
        ]
    return rows


def cmd_report(args):
    lines = ["## Session layer", ""]
    for path in args.results:
        with open(path) as f:
            result = json.load(f)
        runner = result.get("runner", {})
        image = " ".join(
            str(v) for v in (runner.get("image_os"), runner.get("image_version")) if v
        ) or f"{runner.get('system')} {runner.get('release')}"
        title = f"### {runner.get('system')} ({image}, {runner.get('cpus')} CPUs)"
        lines += [title, ""]
        arms = result["arms"]

        pairs = pair_rows(arms)
        if pairs:
            lines += [
                "Local panes, v1 and v2 in one run, alternated:",
                "",
                "| Measurement | v1 | v2 | v2 / v1 |",
                "|---|---:|---:|---:|",
            ]
            for label, v1, v2, number in pairs:
                lines.append(
                    f"| {label} | {number.format(v1)} | {number.format(v2)} | {ratio(v1, v2)} |"
                )
            lines.append("")

        if result.get("network"):
            lines += [f"Network: {result['network']}.", ""]
        if result.get("ssh"):
            lines += [f"ssh client: {result['ssh']}.", ""]
        lines += [
            "| Measurement | n | p50 ms | p95 ms | p99 ms | max ms | Load |",
            "|---|---:|---:|---:|---:|---:|---:|",
        ]
        for arm, label in ARM_LABELS.items():
            data = arms.get(arm)
            if not data:
                continue
            gate = data.get("load_gate", {})
            load = f"{gate.get('load', '—')}" + ("" if gate.get("passed", True) else " ⚠️")
            # A tail percentile of a few samples is only the max.
            tail = (
                f"{data['p95_ms']:.3f} | {data['p99_ms']:.3f}" if data["n"] >= 20 else "— | —"
            )
            lines.append(
                f"| {label} | {data['n']} | {data['p50_ms']:.3f} | {tail} "
                f"| {data['max_ms']:.3f} | {load} |"
            )
        for layer in LAYERS:
            reattach = arms.get(f"reattach-{layer}")
            if reattach:
                lines += [
                    "",
                    f"Reattach, {layer}, replays {reattach['lines']} lines of "
                    f"{reattach['columns']} columns: {reattach['replay_bytes'] / 1024:.0f} KiB.",
                ]

        idle = arms.get("idle")
        if idle:
            gate = idle.get("load_gate", {})
            load = f"{gate.get('load', '—')}" + ("" if gate.get("passed", True) else " ⚠️")
            lines += [
                "",
                f"Idle panes, wakeups over {idle['seconds']} s, load {load}. The session side "
                "is v1's daemons, or v2's server and sessions:",
                "",
                "| Panes | Layer | Session side MB | Clients MB | Session side wakeups/s "
                "| Clients wakeups/s |",
                "|---:|---|---:|---:|---:|---:|",
            ]
            for size, layers in idle["panes"].items():
                for layer in LAYERS:
                    data = layers[layer]
                    lines.append(
                        f"| {size} | {layer} | {data['session_mb']:.1f} | {data['client_mb']:.1f} "
                        f"| {data['session_wakeups_per_s']:.1f} "
                        f"| {data['client_wakeups_per_s']:.1f} |"
                    )
        lines.append("")
    lines.append(
        "_Load is the 1-minute load average when the measurement started. ⚠️ means "
        "the load did not drop below the gate in time._"
    )
    print("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="measure every arm and write a results JSON")
    run.add_argument("--zmx", required=True, help="path to the zmx binary")
    run.add_argument("--out", required=True, help="path for the results JSON")
    run.add_argument("--keys", type=int, default=500, help="keys per echo arm")
    run.add_argument("--rounds", type=int, default=10,
                     help="rounds in which the echo keys alternate between v1 and v2")
    run.add_argument("--ssh-host",
                     help="also measure the ssh arms against this host, which has zmx "
                          "at the same path as --zmx")
    run.add_argument("--network", help="a note on the network to the ssh host, for the report")
    run.add_argument("--panes", type=int, default=5, help="new remote panes to time")
    run.add_argument("--reattach-lines", type=int, default=10000,
                     help="lines of 200 columns in the reattached session")
    run.add_argument("--attaches", type=int, default=5, help="reattaches to time, in each layer")
    run.add_argument("--idle-panes", type=lambda v: [int(n) for n in v.split(",")],
                     default=[1, 9], help="pane counts at which to measure idle cost (macOS)")
    run.add_argument("--idle-seconds", type=int, default=60,
                     help="seconds over which to count the wakeups of idle panes")
    run.add_argument("--idle-settle", type=int, default=5,
                     help="seconds to wait after the panes open, before the idle reads")
    run.add_argument("--max-load", type=float,
                     help="1-minute load average to wait for before each arm "
                          "(default: half the CPU count, at least 1)")
    run.add_argument("--load-timeout", type=int, default=120,
                     help="seconds to wait for the load gate")
    run.set_defaults(func=cmd_run)

    report = sub.add_parser("report", help="render results as markdown")
    report.add_argument("results", nargs="+", help="results JSONs from `run`")
    report.set_defaults(func=cmd_report)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
