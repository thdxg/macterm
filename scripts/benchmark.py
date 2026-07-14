#!/usr/bin/env python3
"""Window-state resource benchmark.

Measures Macterm's CPU and memory across three window states — focused,
open-but-unfocused, and minimized — by launching the app with the
MACTERM_BENCHMARK=1 control hook (Macterm/App/BenchmarkControl.swift) and
driving it with Darwin notifications (`notifyutil -p`) plus LaunchServices
activation (`open`). Neither needs a TCC grant, so this runs on a stock CI
runner.

Per state: settle, then sample several short windows and report the
per-metric median — each window reads the process's CPU-time delta (the
primary metric — immune to sampling aliasing) and median RSS. Taking the
median across windows keeps a single co-scheduled CPU spike on a shared
runner from skewing a state. When passwordless sudo is available (GitHub
runners), a concurrent `powermetrics --samplers tasks` window adds
idle-wakeups/s and CPU ms/s; inside virtualized runners powermetrics is
best-effort and the fields are null when it fails.

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
# With --workload, the same three states are re-sampled after spawning busy
# tabs/panes via the bundled `macterm` CLI. Separate keys keep the idle
# states comparable against pre-workload baselines: a baseline that lacks a
# state simply shows no delta for it (first run after enabling), while
# focused/unfocused/minimized keep their history.
WORKLOAD_STATES = tuple(f"workload-{state}" for state in STATES)
NOTIFY_PREFIX = "com.thdxg.macterm.bench."
# Runs in every workload pane: a real external child process emitting a line
# a second — "logs trickling in" — without meaningful CPU of its own. Typed
# into the pane's shell verbatim, so it must parse in POSIX shells AND
# nushell; invoking /bin/sh with a quoted script does.
WORKLOAD_COMMAND = '/bin/sh -c "while :; do date; sleep 1; done"'


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


def sample_window(pid, seconds):
    """One contiguous sampling window: the process's CPU-time rate over the
    window, its median RSS, and (best-effort) powermetrics CPU ms/s + wakeups/s.
    A single reading — `sample_state` runs several and medians them so one
    unlucky window (a shared-runner co-scheduled spike) can't skew the result.
    """
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


def _median_or_none(values):
    """Median of the non-null values, or None if none are present. Powermetrics
    fields go null when it can't run (virtualized runners), so a state's windows
    may have a mix — median only what we actually measured."""
    present = [v for v in values if v is not None]
    return round(statistics.median(present), 3) if present else None


def sample_state(pid, seconds, samples):
    """Sample a state over `samples` back-to-back windows of `seconds` each and
    return the per-metric median. Splitting one long window into several short
    ones and taking the median keeps a single co-scheduled CPU spike on a shared
    CI runner from dominating the reading, at the same total wall-clock cost.
    With samples == 1 this is exactly one `sample_window` call (unchanged
    behavior for a local one-shot run)."""
    windows = []
    for i in range(samples):
        window = sample_window(pid, seconds)
        windows.append(window)
        if samples > 1:
            print(f"    window {i + 1}/{samples}: {window}", flush=True)
    if samples == 1:
        return windows[0]
    return {
        "cpu_pct": _median_or_none([w["cpu_pct"] for w in windows]),
        "rss_mb": _median_or_none([w["rss_mb"] for w in windows]),
        "cpu_ms_per_s": _median_or_none([w["cpu_ms_per_s"] for w in windows]),
        "wakeups_per_s": _median_or_none([w["wakeups_per_s"] for w in windows]),
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


def enter_state(app, state):
    """Drive the window into a (possibly workload-prefixed) state."""
    base = state.removeprefix("workload-")
    if base == "focused":
        # The window may be minimized from the previous round; restore is
        # idempotent when it isn't. `open` on the running bundle activates
        # via LaunchServices (user-intent level, unlike cooperative
        # NSApp.activate).
        notify("restore")
        sh(["open", app])
        notify("activate")
    elif base == "unfocused":
        notify("restore")
        sh(["open", "-a", "Finder"])
    elif base == "minimized":
        notify("minimize")


def spawn_workload(app, data_dir, tabs, out_path):
    """Spawn `tabs` busy tabs (2×2 grid each) through the bundled CLI.

    Fails hard on any miss: silently sampling a partial workload would
    compare unlike against unlike across runs.
    """
    cli = os.path.join(app, "Contents", "Resources", "bin", "macterm")
    socket = os.path.join(data_dir, "control.sock")
    if not os.path.exists(cli):
        sys.exit("error: bundled macterm CLI missing from the app")

    def cli_run(*cli_args):
        result = sh([cli, *cli_args, "--socket", socket])
        if result.returncode != 0:
            dump_diagnostics(out_path)
            sys.exit(f"error: macterm {' '.join(cli_args)} failed: {result.stderr.strip()}")
        return result

    # The socket answers `starting` until AppState attaches; by this point
    # the project is open so one poll round is usually enough.
    for _ in range(30):
        probe = sh([cli, "status", "--socket", socket])
        if probe.returncode == 0:
            break
        time.sleep(1)
    else:
        dump_diagnostics(out_path)
        sys.exit(
            "error: control socket never became ready for the workload: "
            f"{probe.stderr.strip()}"
        )

    print(f"spawning workload: {tabs} tabs x 4 panes", flush=True)
    for _ in range(tabs):
        cli_run("tab", "new", "--run", WORKLOAD_COMMAND)
        cli_run("grid", "2x2", "--run", WORKLOAD_COMMAND)
        # Pace the spawn burst: each tab is 4 shells + zmx sessions, and a
        # mass simultaneous spawn is its own pathology (PAM/memory storm),
        # not the steady state this measures.
        time.sleep(0.5)

    listing = json.loads(cli_run("pane", "list", "--json").stdout)
    panes = listing.get("panes") or []
    expected = 1 + tabs * 4  # the project's original idle pane + the grids
    if len(panes) != expected:
        dump_diagnostics(out_path)
        sys.exit(f"error: workload spawned {len(panes)} panes, expected {expected}")


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
    #
    # Rooted in /tmp, NOT the default $TMPDIR: the control socket lives at
    # <data-dir>/control.sock, and a Unix socket path must fit sun_path
    # (~104 bytes). CI runners' $TMPDIR (/var/folders/…/T/) pushes the path
    # right past that, so the app refuses to bind and the workload can never
    # connect. /tmp keeps it ~50 bytes with room to spare.
    home = tempfile.mkdtemp(prefix="macterm-bench-home-", dir="/tmp")
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

    # Match the launched process by its EXACT executable path, not a loose
    # `pgrep -f <path>` (which treats the path as a regex — an unescaped `.` in
    # the build dir matches any char — and blindly takes the first pid). Escape
    # the path for the regex, then verify each candidate's real command line
    # points at our binary, so a leftover instance from an aborted run can't be
    # sampled/killed instead of the fresh launch.
    pid = None
    for _ in range(20):
        pids = sh(["pgrep", "-f", "--", re.escape(binary)]).stdout.split()
        for candidate in pids:
            command = sh(["ps", "-p", candidate, "-o", "command="]).stdout.strip()
            if command.startswith(binary):
                pid = int(candidate)
                break
        if pid is not None:
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
        state_plan = list(STATES)
        for state in state_plan:
            enter_state(app, state)
            time.sleep(args.settle)
            print(f"sampling {state}: {args.samples}x{args.seconds}s", flush=True)
            results[state] = sample_state(pid, args.seconds, args.samples)
            print(f"  {results[state]}", flush=True)

        if args.workload > 0:
            # Re-run the same three states with busy tabs on screen so the
            # numbers reflect an app doing real terminal work, not an empty
            # window. Spawn while restored (surfaces need a window).
            enter_state(app, "focused")
            spawn_workload(app, bench_env["MACTERM_BENCHMARK_DATA_DIR"], args.workload, args.out)
            time.sleep(args.boot_settle)
            for state in WORKLOAD_STATES:
                enter_state(app, state)
                time.sleep(args.settle)
                print(f"sampling {state}: {args.samples}x{args.seconds}s", flush=True)
                results[state] = sample_state(pid, args.seconds, args.samples)
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
        "schema": 2,
        "commit": git_sha(),
        # Each state is observed for samples x seconds total, split into
        # `samples` windows whose per-metric median is what `states` records.
        # `seconds_per_state` stays the TOTAL observation time (back-compat with
        # a schema-1 reader) — samples/seconds_per_window describe the split.
        "seconds_per_state": args.seconds * args.samples,
        "seconds_per_window": args.seconds,
        "samples_per_state": args.samples,
        "states": results,
    }
    if args.workload > 0:
        payload["workload"] = {
            "tabs": args.workload,
            "panes_per_tab": 4,
            "command": WORKLOAD_COMMAND,
        }
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(payload, f, indent=2)
    print(f"wrote {args.out}")


# The relative bar: a delta must move at least this % to be flagged.
THRESHOLD_PCT = 25
# On top of the relative bar, each metric carries two absolute guards — a delta
# must clear ALL THREE to be FLAGGED (labeled). The raw % still always prints in
# the table; these only gate the 🔺/🔻 and the label:
#   - floor: minimum absolute change. Stops "0.03 → 0.05 = +66%" on a tiny base.
#   - min_baseline: minimum baseline VALUE. Below this the metric is dominated
#     by shared-runner scheduling jitter, so a big relative swing off it isn't
#     a real regression — e.g. a focused-idle app legitimately wanders 0.6–1.4%
#     CPU depending on what the runner co-schedules. Only the CPU metrics need
#     it (RSS/wakeups aren't noise-dominated at low values); None disables it.
METRICS = (
    # key, table label, format, absolute noise floor, min baseline to flag
    ("cpu_pct", "CPU %", "{:.2f}", 0.5, 1.5),
    ("rss_mb", "Memory (RSS MB)", "{:.1f}", 25.0, None),
    ("cpu_ms_per_s", "CPU ms/s (powermetrics)", "{:.1f}", 5.0, 15.0),
    ("wakeups_per_s", "Wakeups/s (powermetrics)", "{:.1f}", 50.0, None),
)


def fmt(value, pattern):
    return pattern.format(value) if value is not None else "—"


def significant_pct(base, current, floor, min_baseline=None):
    """Signed % change if it clears every noise guard (positive = regression),
    else None. A guarded-out delta still displays its raw % — this only governs
    whether it's flagged/labeled. Guards: relative threshold, absolute floor,
    and (when set) a minimum baseline below which the reading is noise."""
    if base is None or current is None or base == 0:
        return None
    if min_baseline is not None and base < min_baseline:
        return None
    diff = current - base
    pct = diff / base * 100
    if abs(pct) >= THRESHOLD_PCT and abs(diff) >= floor:
        return pct
    return None


def delta_cell(base, current, floor, min_baseline=None):
    if base is None or current is None:
        return "—"
    diff = current - base
    if base == 0:
        return "—" if diff == 0 else f"+{diff:.2f}"
    sig = significant_pct(base, current, floor, min_baseline)
    arrow = "" if sig is None else ("🔺" if sig > 0 else "🔻")
    return f"{diff / base * 100:+.0f}% {arrow}".strip()


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

    regressions, improvements = [], []
    workload_missing_baseline = False
    for state in STATES + WORKLOAD_STATES:
        cur_state = current["states"].get(state, {})
        if not cur_state:
            continue  # e.g. a run without --workload
        base_state = (baseline or {}).get("states", {}).get(state, {})
        if baseline and state in WORKLOAD_STATES and not base_state:
            workload_missing_baseline = True
        state_cell = state  # only label the state's first row
        for key, label, pattern, floor, min_baseline in METRICS:
            cur = cur_state.get(key)
            if cur is None and (not baseline or base_state.get(key) is None):
                continue
            if baseline:
                base = base_state.get(key)
                lines.append(
                    f"| {state_cell} | {label} | {fmt(base, pattern)} "
                    f"| {fmt(cur, pattern)} | {delta_cell(base, cur, floor, min_baseline)} |"
                )
                sig = significant_pct(base, cur, floor, min_baseline)
                if sig is not None:
                    bucket = regressions if sig > 0 else improvements
                    bucket.append({
                        "state": state,
                        "metric": label,
                        "base": base,
                        "current": cur,
                        "pct": round(sig),
                        "pattern": pattern,
                    })
            else:
                lines.append(f"| {state_cell} | {label} | {fmt(cur, pattern)} |")
            state_cell = ""

    for entries, label_name, verdict_line in (
        (regressions, "benchmark:regression", "regressed"),
        (improvements, "benchmark:improvement", "improved"),
    ):
        if not entries:
            continue
        lines += [
            "",
            f"### {'⚠️' if verdict_line == 'regressed' else '🎉'} Labeled `{label_name}`",
            "",
            f"This PR is labeled `{label_name}` because these metrics {verdict_line} "
            f"by ≥{THRESHOLD_PCT}% vs {base_ref} (beyond each metric's absolute noise floor):",
            "",
        ]
        lines += [
            f"- **{e['state']} — {e['metric']}**: "
            f"{fmt(e['base'], e['pattern'])} → {fmt(e['current'], e['pattern'])} ({e['pct']:+d}%)"
            for e in entries
        ]

    floors = ", ".join(
        f"{label.replace(' (powermetrics)', '')} ≥{floor:g}"
        for _, label, _, floor, _ in METRICS
    )
    gates = ", ".join(
        f"{label.replace(' (powermetrics)', '')} baseline ≥{min_baseline:g}"
        for _, label, _, _, min_baseline in METRICS if min_baseline is not None
    )
    samples = current.get("samples_per_state", 1)
    window = current.get("seconds_per_window", current["seconds_per_state"])
    if samples > 1:
        sampling = (
            f"median of {samples}×{window}s windows per state (splitting the window "
            "and taking the median keeps one co-scheduled spike from skewing a state)"
        )
    else:
        sampling = f"{window}s window per state"
    lines += [
        "",
        f"_Reported value is the {sampling}; CPU % is the process CPU-time delta "
        "over a window. Runs land on different "
        f"shared runners, so treat small deltas as noise — 🔺/🔻 marks changes ≥{THRESHOLD_PCT}% "
        f"that also clear the metric's absolute noise floor ({floors}); CPU deltas off a "
        f"noise-dominated baseline aren't flagged ({gates}). Flagged changes "
        "add the `benchmark:regression` / `benchmark:improvement` label._",
    ]
    if baseline is None:
        lines.append("")
        lines.append("_No main-branch baseline found; showing absolute values only._")
    elif workload_missing_baseline:
        lines.append("")
        lines.append(
            "_The `workload-*` states (busy tabs spawned via the `macterm` CLI) "
            "have no baseline yet — deltas for them appear once main's baseline "
            "includes a workload run._"
        )
    print("\n".join(lines))

    if args.verdict:
        with open(args.verdict, "w") as f:
            json.dump({
                "regression": bool(regressions),
                "improvement": bool(improvements),
                "regressions": regressions,
                "improvements": improvements,
            }, f, indent=2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    run = sub.add_parser("run", help="launch the app and benchmark each window state")
    run.add_argument("--app", required=True, help="path to the built Macterm.app")
    run.add_argument("--out", required=True, help="path for the results JSON")
    run.add_argument("--seconds", type=int, default=10, help="length of each sampling window")
    run.add_argument(
        "--samples", type=int, default=3, metavar="K",
        help="windows sampled per state; the per-metric median is reported, so a "
             "single co-scheduled CPU spike on a shared runner can't skew a state "
             "(default: 3). Total wall-clock per state is samples x seconds.",
    )
    run.add_argument("--settle", type=int, default=5, help="settle time after each state change")
    run.add_argument("--boot-settle", type=int, default=10, help="settle time after launch / project open")
    run.add_argument(
        "--workload", type=int, default=0, metavar="TABS",
        help="also sample workload-* states after spawning TABS busy tabs "
             "(2x2 grid each) via the bundled macterm CLI (default: off)",
    )
    run.set_defaults(func=cmd_run)

    report = sub.add_parser("report", help="render results as markdown")
    report.add_argument("results", help="results JSON from `run`")
    report.add_argument("--baseline", help="baseline results JSON to compare against")
    report.add_argument("--verdict", help="also write a labeling verdict JSON to this path")
    report.set_defaults(func=cmd_report)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
