#!/usr/bin/env python3
"""Session-layer latency benchmark.

Measures the part of typing latency and reattach time that the session layer
(zmx, and ssh for remote panes) adds. It runs no app: a pty driver plays the
part of the terminal, so it runs on any CI runner, macOS or Linux.

Arms (each is a program on a pty that this script drives):

  bare       /bin/cat on a pty. The floor: the kernel's own echo.
  zmx        `zmx attach <s> /bin/cat`. A local pane of Macterm v1.
  ssh        `ssh -tt <host> /bin/cat`. The floor for a remote pane.
  ssh-zmx    `ssh -tt <host> zmx attach <s> /bin/cat`. A remote pane of v1.

Echo latency: write one key, time until the echo arrives, for --keys keys.
Remote pane open: time from the start of `ssh … zmx attach` to the first
echo. v1 makes a new ssh login for each remote pane.
Reattach: fill a session with --reattach-lines lines of 200 columns, detach,
then time a new `zmx attach` until the echo of a marker line that is sent
after the client takes the terminal. The echo comes after the replay.

Load decides latency on a shared runner, so each arm first waits for the
1-minute load average to drop below --max-load and records the load.

Subcommands:
  run     measure every arm, write a results JSON
  report  render one or more results JSONs as markdown
"""

import argparse
import fcntl
import json
import os
import platform
import select
import shlex
import shutil
import signal
import statistics
import struct
import subprocess
import sys
import tempfile
import termios
import time
import uuid

from _harness import wait_for_load

COLUMNS = 200
ROWS = 50
DETACH_KEY = b"\x1c"  # ctrl+\: zmx detaches the current client.


class BenchError(Exception):
    pass


# ── Runner ──────────────────────────────────────────────────────


def runner_info():
    """The runner image and OS, so that a reader pools only like with like.
    GitHub's hosted runners export ImageOS and ImageVersion."""
    info = {
        "image_os": os.environ.get("ImageOS"),
        "image_version": os.environ.get("ImageVersion"),
        "system": platform.system(),
        "release": platform.release(),
        "machine": platform.machine(),
        "cpus": os.cpu_count(),
    }
    if platform.system() == "Darwin":
        info["macos"] = platform.mac_ver()[0]
    return info


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
        start = len(self.output) if since is None else since
        deadline = time.monotonic() + timeout
        # A needle can arrive split across reads, so look back by its length.
        while needle not in self.output[max(start, 0):]:
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


def wait_ready(program, takes_terminal=True, timeout=30):
    """Wait until the program has the terminal and its far end echoes. A
    program that does not take the terminal (bare cat) echoes through the
    pty's own line discipline."""
    if takes_terminal:
        program.wait_raw(timeout)
    offset = len(program.output)
    program.write(b"@")
    first_echo = program.read_until(b"@", timeout, since=offset)
    program.write(b"\n")
    program.drain()
    return first_echo


# ── Arms ─────────────────────────────────────────────────────────────────


class Bench:
    def __init__(self, args):
        self.args = args
        self.nonce = uuid.uuid4().hex[:8]
        # /tmp, not $TMPDIR: zmx socket paths must fit sun_path.
        self.zmx_dir = tempfile.mkdtemp(prefix="macterm-session-bench-", dir="/tmp")
        self.env = dict(os.environ, ZMX_DIR=self.zmx_dir, TERM="xterm-256color")
        self.local_sessions = []
        self.remote_sessions = []

    def session(self, label, remote=False):
        name = f"bench-{label}-{self.nonce}"
        (self.remote_sessions if remote else self.local_sessions).append(name)
        return name

    def zmx_attach(self, name, command=None):
        return [self.args.zmx, "attach", name, *(command or [])]

    def ssh(self, remote_command):
        return [
            "ssh", "-tt", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no",
            self.args.ssh_host, remote_command,
        ]

    def remote_zmx(self, *words):
        return " ".join(
            [f"ZMX_DIR={shlex.quote(self.zmx_dir)}", shlex.quote(self.args.remote_zmx)]
            + [shlex.quote(word) for word in words]
        )

    def gate(self):
        return wait_for_load(self.args.max_load, self.args.load_timeout)

    def echo_arm(self, name, argv, takes_terminal=True):
        gate = self.gate()
        print(f"{name}: load {gate['load']}, {self.args.keys} keys", flush=True)
        program = PtyProgram(argv, self.env)
        try:
            wait_ready(program, takes_terminal)
            result = summarize(echo_latencies(program, self.args.keys))
        finally:
            program.close()
        result["load_gate"] = gate
        print(f"  {result}", flush=True)
        return result

    def remote_pane_open(self):
        """Time a new remote pane: ssh login, then zmx attach, until the
        first echo."""
        gate = self.gate()
        print(f"remote-pane-open: load {gate['load']}, {self.args.panes} panes", flush=True)
        samples = []
        for i in range(self.args.panes):
            name = self.session(f"pane{i}", remote=True)
            program = PtyProgram(self.ssh(self.remote_zmx("attach", name, "/bin/cat")), self.env)
            try:
                first_echo = wait_ready(program)
                samples.append((first_echo - program.started) * 1000)
            finally:
                program.close()
        result = summarize(samples)
        result["load_gate"] = gate
        print(f"  {result}", flush=True)
        return result

    def reattach(self):
        lines = self.args.reattach_lines
        name = self.session("reattach")
        marker = f"fill-done-{self.nonce}"
        # 6 characters of line number and 193 dots: 199 columns, so that no
        # line wraps on the 200-column terminal.
        script = (
            f'i=0; while [ $i -lt {lines} ]; do printf "%05d %s\\n" $i "{"." * 193}"; '
            f"i=$((i+1)); done; printf '%s\\n' {marker}; stty -echo; "
            "exec awk '{print \"got-\" $0; fflush()}'"
        )
        fill = PtyProgram(self.zmx_attach(name, ["/bin/sh", "-c", script]), self.env)
        try:
            fill.wait_raw(30)
            fill.read_until(marker.encode(), timeout=120, since=0)
            fill.write(DETACH_KEY)
            if not fill.wait_exit(10):
                raise BenchError("zmx did not detach the filling client")
        finally:
            fill.close()

        gate = self.gate()
        print(f"reattach: load {gate['load']}, {lines} lines, {self.args.attaches} attaches",
              flush=True)
        samples, replay_bytes = [], []
        for i in range(self.args.attaches):
            token = f"m{self.nonce}r{i}x"
            program = PtyProgram(self.zmx_attach(name), self.env)
            try:
                program.wait_raw(30)
                program.write(f"{token}\n".encode())
                end = program.read_until(f"got-{token}".encode(), timeout=60, since=0)
                samples.append((end - program.started) * 1000)
                replay_bytes.append(len(program.output))
                program.write(DETACH_KEY)
                program.wait_exit(10)
            finally:
                program.close()
        result = summarize(samples)
        result["lines"] = lines
        result["columns"] = COLUMNS
        result["replay_bytes"] = int(statistics.median(replay_bytes))
        result["load_gate"] = gate
        print(f"  {result}", flush=True)
        return result

    def cleanup(self):
        # A session with no client keeps running and drops terminal replies,
        # so every session that this run made is killed, local and remote.
        if self.local_sessions:
            subprocess.run(
                [self.args.zmx, "kill", *self.local_sessions, "--force"],
                env=self.env, capture_output=True, timeout=30, check=False,
            )
        if self.remote_sessions:
            subprocess.run(
                ["ssh", "-o", "BatchMode=yes", self.args.ssh_host,
                 self.remote_zmx("kill", *self.remote_sessions, "--force")],
                capture_output=True, timeout=60, check=False,
            )
        shutil.rmtree(self.zmx_dir, ignore_errors=True)


def cmd_run(args):
    args.zmx = os.path.abspath(args.zmx)
    args.remote_zmx = args.remote_zmx or args.zmx
    if args.max_load is None:
        args.max_load = max(1.0, os.cpu_count() / 2)
    bench = Bench(args)
    arms = {}
    try:
        arms["bare"] = bench.echo_arm("bare", ["/bin/cat"], takes_terminal=False)
        arms["zmx"] = bench.echo_arm("zmx", bench.zmx_attach(bench.session("echo"), ["/bin/cat"]))
        if args.ssh_host:
            arms["ssh"] = bench.echo_arm("ssh", bench.ssh("/bin/cat"))
            arms["ssh-zmx"] = bench.echo_arm(
                "ssh-zmx",
                bench.ssh(bench.remote_zmx("attach", bench.session("echo", remote=True), "/bin/cat")),
            )
            arms["remote-pane-open"] = bench.remote_pane_open()
        arms["reattach"] = bench.reattach()
    except BenchError as exc:
        sys.exit(f"error: {exc}")
    finally:
        bench.cleanup()

    version = subprocess.run([args.zmx, "version"], capture_output=True, text=True, check=False)
    payload = {
        "schema": 1,
        "commit": os.environ.get("GITHUB_SHA") or subprocess.run(
            ["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=False
        ).stdout.strip() or "unknown",
        "runner": runner_info(),
        "zmx": version.stdout.split("\n", 1)[0].split()[-1] if version.stdout else None,
        "network": args.network,
        "arms": arms,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(payload, f, indent=2)
    print(f"wrote {args.out}")


ARM_LABELS = {
    "bare": "Echo, bare pty (floor)",
    "zmx": "Echo, local pane (zmx)",
    "ssh": "Echo, ssh (floor)",
    "ssh-zmx": "Echo, remote pane (ssh + zmx)",
    "remote-pane-open": "New remote pane, to first echo",
    "reattach": "Reattach, to first echo after replay",
}


def cmd_report(args):
    lines = ["## Session-layer latency", ""]
    for path in args.results:
        with open(path) as f:
            result = json.load(f)
        runner = result.get("runner", {})
        image = " ".join(
            str(v) for v in (runner.get("image_os"), runner.get("image_version")) if v
        ) or f"{runner.get('system')} {runner.get('release')}"
        title = f"### {runner.get('system')} ({image}, {runner.get('cpus')} CPUs)"
        lines += [title, ""]
        if result.get("network"):
            lines += [f"Network: {result['network']}.", ""]
        lines += ["| Measurement | n | p50 ms | p95 ms | p99 ms | Load |", "|---|---:|---:|---:|---:|---:|"]
        for arm, label in ARM_LABELS.items():
            data = result["arms"].get(arm)
            if not data:
                continue
            gate = data.get("load_gate", {})
            load = f"{gate.get('load', '—')}" + ("" if gate.get("passed", True) else " ⚠️")
            lines.append(
                f"| {label} | {data['n']} | {data['p50_ms']:.3f} | {data['p95_ms']:.3f} "
                f"| {data['p99_ms']:.3f} | {load} |"
            )
        reattach = result["arms"].get("reattach")
        if reattach:
            lines += [
                "",
                f"Reattach replays {reattach['lines']} lines of {reattach['columns']} columns: "
                f"{reattach['replay_bytes'] / 1024:.0f} KiB.",
            ]
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
    run.add_argument("--ssh-host", help="also measure the ssh arms against this host")
    run.add_argument("--remote-zmx", help="path to zmx on the ssh host (default: --zmx)")
    run.add_argument("--network", help="a note on the network to the ssh host, for the report")
    run.add_argument("--panes", type=int, default=5, help="new remote panes to time")
    run.add_argument("--reattach-lines", type=int, default=10000,
                     help="lines of 200 columns in the reattached session")
    run.add_argument("--attaches", type=int, default=5, help="reattaches to time")
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
