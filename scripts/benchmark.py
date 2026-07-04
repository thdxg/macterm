#!/usr/bin/env python3
"""Window-state resource benchmark.

Measures Macterm's CPU and memory across three window states — focused,
open-but-unfocused, and minimized — by launching the app with the
MACTERM_BENCHMARK=1 control hook (Macterm/App/BenchmarkControl.swift) and
driving it with Darwin notifications (`notifyutil -p`) plus LaunchServices
activation (`open`). Neither needs a TCC grant, so this runs on a stock CI
runner.

Per state: settle, then over a sampling window read the process's CPU-time
delta (the primary metric — immune to sampling aliasing) and median RSS.
When passwordless sudo is available (GitHub runners), a concurrent
`powermetrics --samplers tasks` window adds idle-wakeups/s and CPU ms/s;
inside virtualized runners powermetrics is best-effort and the fields are
null when it fails.

Subcommands:
  run     launch the app, sample each state, write a results JSON
  report  render a results JSON (optionally vs. a baseline) as markdown
"""

import argparse
import json
import os
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import time

STATES = ("focused", "unfocused", "minimized")
NOTIFY_PREFIX = "com.thdxg.macterm.bench."


def sh(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, **kwargs)


def notify(command):
    sh(["notifyutil", "-p", NOTIFY_PREFIX + command])


def read_info_plist_key(app, key):
    result = sh(["defaults", "read", os.path.join(app, "Contents", "Info"), key])
    if result.returncode != 0:
        sys.exit(f"error: cannot read {key} from {app}: {result.stderr.strip()}")
    return result.stdout.strip()


def parse_cputime(value):
    """ps cputime: [[dd-]hh:]mm:ss.cc → seconds."""
    days = 0
    if "-" in value:
        day_part, value = value.split("-", 1)
        days = int(day_part)
    parts = [float(p) for p in value.split(":")]
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + part
    return days * 86400 + seconds


def ps_sample(pid):
    """Return (cputime_seconds, rss_kb) or None if the process is gone."""
    result = sh(["ps", "-p", str(pid), "-o", "cputime=,rss="])
    fields = result.stdout.split()
    if result.returncode != 0 or len(fields) != 2:
        return None
    return parse_cputime(fields[0]), int(fields[1])


def start_powermetrics(seconds):
    """Kick off one powermetrics tasks-sampler window; None if sudo needs a password."""
    if sh(["sudo", "-n", "true"]).returncode != 0:
        return None
    return subprocess.Popen(
        ["sudo", "-n", "powermetrics", "--samplers", "tasks",
         "-i", str(seconds * 1000), "-n", "1"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )


def parse_powermetrics(output, pid):
    """Pull (cpu_ms_per_s, wakeups_per_s) for pid from a tasks-sampler table.

    Rows are `Name  ID  CPU ms/s  User%  Deadlines (<2 ms, 2-5 ms)  Wakeups
    (Intr, Pkg idle)` with an optional trailing GPU ms/s column depending on
    the macOS release — so index the numeric fields from the front, never the
    back. The name can contain spaces; anchor on the pid column instead.
    """
    for line in output.splitlines():
        tokens = line.split()
        try:
            pid_index = tokens.index(str(pid))
        except ValueError:
            continue
        numbers = []
        for token in tokens[pid_index + 1:]:
            match = re.match(r"^\d+(\.\d+)?$", token)
            if match:
                numbers.append(float(token))
        if len(numbers) >= 6:
            # cpu, user%, deadline1, deadline2, wakeups-intr, wakeups-pkg-idle
            return numbers[0], numbers[4] + numbers[5]
    return None


def check_alive(pid):
    # The app is launchd's child (launched via `open`), so it vanishes from
    # ps on death — but guard against a lingering zombie too, which ps still
    # reports (with rss 0 and a reset cputime).
    result = sh(["ps", "-p", str(pid), "-o", "state="])
    state = result.stdout.strip()
    if result.returncode != 0 or not state or state.startswith("Z"):
        sys.exit("error: app process died mid-benchmark")


def sample_state(pid, seconds):
    check_alive(pid)
    start = ps_sample(pid)
    if start is None:
        sys.exit("error: app process not sampleable")
    power = start_powermetrics(seconds)

    rss_samples = []
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        time.sleep(1)
        check_alive(pid)
        sample = ps_sample(pid)
        if sample is None:
            sys.exit("error: app process died mid-sample")
        rss_samples.append(sample[1])
    end = ps_sample(pid)

    cpu_ms_per_s = wakeups_per_s = None
    if power is not None:
        try:
            output, _ = power.communicate(timeout=seconds + 30)
            parsed = parse_powermetrics(output, pid)
            if parsed:
                cpu_ms_per_s, wakeups_per_s = parsed
        except subprocess.TimeoutExpired:
            power.kill()

    return {
        "cpu_pct": round((end[0] - start[0]) / seconds * 100, 3),
        "rss_mb": round(statistics.median(rss_samples) / 1024, 1),
        "cpu_ms_per_s": cpu_ms_per_s,
        "wakeups_per_s": wakeups_per_s,
    }


def dump_diagnostics(out_path):
    """On failure, surface what the app saw: its log lines and a screenshot."""
    diag_dir = os.path.join(os.path.dirname(os.path.abspath(out_path)), "diagnostics")
    os.makedirs(diag_dir, exist_ok=True)
    sh(["screencapture", "-x", os.path.join(diag_dir, "screen.png")])
    result = sh([
        "log", "show", "--last", "5m", "--style", "compact", "--level", "debug",
        "--predicate", 'subsystem == "com.thdxg.macterm"',
    ])
    print("--- app log ---", flush=True)
    print(result.stdout or result.stderr, flush=True)


def git_sha():
    sha = os.environ.get("GITHUB_SHA")
    if sha:
        return sha
    result = sh(["git", "rev-parse", "HEAD"])
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def cmd_run(args):
    app = os.path.abspath(args.app)
    executable = read_info_plist_key(app, "CFBundleExecutable")
    binary = os.path.join(app, "Contents", "MacOS", executable)

    # Isolate the run. A throwaway $HOME keeps the spawned shell's rc files
    # and $HOME-derived config out of the picture, but App Support and
    # preferences resolve via the user record, NOT $HOME — so app data
    # isolation needs the explicit MACTERM_BENCHMARK_DATA_DIR override
    # (FileStorage.swift). Without it, a local run reads and writes the real
    # app's projects/workspaces.
    home = tempfile.mkdtemp(prefix="macterm-bench-home-")
    bench_env = {
        "MACTERM_BENCHMARK": "1",
        "MACTERM_BENCHMARK_DATA_DIR": os.path.join(home, "app-data"),
        "HOME": home,
    }

    # Launch via LaunchServices rather than exec'ing the binary: launch-time
    # activation counts as user intent, so the app actually becomes active
    # and SwiftUI creates its window. (A directly-exec'd app starts
    # backgrounded, and macOS's cooperative activation can deny post-hoc
    # activation requests indefinitely on a busy desktop — SwiftUI then
    # never creates a window at all.)
    print(f"launching {app}", flush=True)
    env_args = [f"--env={key}={value}" for key, value in bench_env.items()]
    result = sh(["open", "-n", *env_args, app])
    if result.returncode != 0:
        sys.exit(f"error: open failed: {result.stderr.strip()}")

    pid = None
    for _ in range(20):
        pids = sh(["pgrep", "-f", binary]).stdout.split()
        if pids:
            pid = int(pids[0])
            break
        time.sleep(0.5)
    if pid is None:
        sys.exit("error: app process did not appear after launch")

    try:
        time.sleep(args.boot_settle)
        check_alive(pid)

        # Ask the app to open a project so a real shell + surface is on
        # screen. ProjectStore.add saves projects.json into the isolated
        # data dir synchronously, so its existence is the readiness marker;
        # retry (idempotently) rather than sleep-and-hope, since the window
        # this needs only exists once activation was granted.
        project_marker = os.path.join(bench_env["MACTERM_BENCHMARK_DATA_DIR"], "projects.json")
        for _ in range(30):
            notify("activate")
            notify("open-project")
            time.sleep(2)
            check_alive(pid)
            if os.path.exists(project_marker):
                break
        else:
            dump_diagnostics(args.out)
            sys.exit(
                "error: app never opened the benchmark project — window creation "
                "requires app activation; is someone actively using this desktop?"
            )
        # Let the shell spawn and the initial render burst drain.
        time.sleep(args.boot_settle)

        results = {}
        for state in STATES:
            if state == "focused":
                # `open` on the running bundle activates it via LaunchServices
                # (user-intent level, unlike cooperative NSApp.activate).
                sh(["open", app])
                notify("activate")
            elif state == "unfocused":
                sh(["open", "-a", "Finder"])
            elif state == "minimized":
                notify("minimize")
            time.sleep(args.settle)
            print(f"sampling {state} for {args.seconds}s", flush=True)
            results[state] = sample_state(pid, args.seconds)
            print(f"  {results[state]}", flush=True)
    finally:
        # SIGKILL: SIGTERM would hang on the quit-confirmation dialog for the
        # running shell.
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        shutil.rmtree(home, ignore_errors=True)

    payload = {
        "schema": 1,
        "commit": git_sha(),
        "seconds_per_state": args.seconds,
        "states": results,
    }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(payload, f, indent=2)
    print(f"wrote {args.out}")


METRICS = (
    ("cpu_pct", "CPU %", "{:.2f}"),
    ("rss_mb", "Memory (RSS MB)", "{:.1f}"),
    ("cpu_ms_per_s", "CPU ms/s (powermetrics)", "{:.1f}"),
    ("wakeups_per_s", "Wakeups/s (powermetrics)", "{:.1f}"),
)


def fmt(value, pattern):
    return pattern.format(value) if value is not None else "—"


def delta_cell(base, current):
    if base is None or current is None:
        return "—"
    diff = current - base
    if base == 0:
        return "—" if diff == 0 else f"+{diff:.2f}"
    pct = diff / base * 100
    arrow = "🔺" if pct > 25 else ("🔻" if pct < -25 else "")
    return f"{pct:+.0f}% {arrow}".strip()


def cmd_report(args):
    with open(args.results) as f:
        current = json.load(f)
    baseline = None
    if args.baseline:
        with open(args.baseline) as f:
            baseline = json.load(f)

    lines = ["## Window-state benchmark", ""]
    if baseline:
        base_ref = f"main@{baseline.get('commit', 'unknown')[:9]}"
        lines += [
            f"| State | Metric | {base_ref} | this branch | Δ |",
            "|---|---|---:|---:|---:|",
        ]
    else:
        lines += ["| State | Metric | Value |", "|---|---|---:|"]

    for state in STATES:
        cur_state = current["states"].get(state, {})
        base_state = (baseline or {}).get("states", {}).get(state, {})
        for key, label, pattern in METRICS:
            cur = cur_state.get(key)
            if cur is None and (not baseline or base_state.get(key) is None):
                continue
            if baseline:
                base = base_state.get(key)
                lines.append(
                    f"| {state} | {label} | {fmt(base, pattern)} "
                    f"| {fmt(cur, pattern)} | {delta_cell(base, cur)} |"
                )
            else:
                lines.append(f"| {state} | {label} | {fmt(cur, pattern)} |")

    lines += [
        "",
        f"_{current['seconds_per_state']}s sampling window per state; CPU % is the "
        "process CPU-time delta over the window. Runs land on different shared "
        "runners, so treat small deltas as noise — 🔺/🔻 marks ±25%._",
    ]
    if baseline is None:
        lines.append("")
        lines.append("_No main-branch baseline found; showing absolute values only._")
    print("\n".join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="launch the app and benchmark each window state")
    run.add_argument("--app", required=True, help="path to the built Macterm.app")
    run.add_argument("--out", required=True, help="path for the results JSON")
    run.add_argument("--seconds", type=int, default=30, help="sampling window per state")
    run.add_argument("--settle", type=int, default=5, help="settle time after each state change")
    run.add_argument("--boot-settle", type=int, default=10, help="settle time after launch / project open")
    run.set_defaults(func=cmd_run)

    report = sub.add_parser("report", help="render results as markdown")
    report.add_argument("results", help="results JSON from `run`")
    report.add_argument("--baseline", help="baseline results JSON to compare against")
    report.set_defaults(func=cmd_report)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
