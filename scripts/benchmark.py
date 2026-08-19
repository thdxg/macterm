#!/usr/bin/env python3
"""Window-state resource benchmark.

Measures Macterm's CPU and memory across an idle-focused sanity baseline plus
two workload states — focused and unfocused, each with busy tabs on screen —
by launching the app with the MACTERM_BENCHMARK=1 control hook
(Macterm/App/BenchmarkControl.swift) and driving it with Darwin notifications
(`notifyutil -p`) plus LaunchServices activation (`open`). Neither needs a TCC
grant, so this runs on a stock CI runner. (The workload states carry the real
signal; the near-redundant idle unfocused/minimized states were dropped to cut
false-positive labels — fewer cells, fewer noise trips.)

The launch/drive/teardown machinery lives in _harness.py, shared with the e2e
suite (e2e/) — this file owns only the sampling and reporting.

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
import statistics
import subprocess
import sys
import time

from _harness import HarnessError, MactermHarness, notify, sh

# The benchmark samples one idle state as a sanity baseline plus the two
# workload states that carry the real signal — an app doing terminal work,
# focused and unfocused. This deliberately drops the near-redundant idle
# `unfocused`/`minimized` states and `workload-minimized`: 3 states × 4
# metrics = 12 flag-chances instead of 24, which is the dominant lever on
# false-positive labels (fewer independent cells → fewer noise trips). The
# idle `focused` state stays as a coarse baseline but, being the noisiest
# (idle CPU wanders with the runner's co-scheduling — see min_baseline), it
# never drives a label on its own (see `cmd_report`'s ≥2-cells verdict).
IDLE_STATES = ("focused",)
# Sampled after spawning busy tabs/panes via the bundled `macterm` CLI. The
# `workload-` prefix keeps them separate keys so the idle baseline stays
# comparable against pre-workload history: a baseline lacking a state simply
# shows no delta for it (first run after enabling).
WORKLOAD_STATES = ("workload-focused", "workload-unfocused")
# Every state the run samples and the report renders, in display order.
STATES = IDLE_STATES + WORKLOAD_STATES
# Runs in every workload pane: a real external child process emitting a line
# a second — "logs trickling in" — without meaningful CPU of its own. Typed
# into the pane's shell verbatim, so it must parse in POSIX shells AND
# nushell; invoking /bin/sh with a quoted script does.
WORKLOAD_COMMAND = '/bin/sh -c "while :; do date; sleep 1; done"'


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


def check_alive(harness):
    # Zombie-aware liveness (see MactermHarness.is_alive); dying mid-run is
    # always fatal to the benchmark.
    if not harness.is_alive():
        sys.exit("error: app process died mid-benchmark")


def sample_window(harness, seconds):
    """One contiguous sampling window: the process's CPU-time rate over the
    window, its median RSS, and (best-effort) powermetrics CPU ms/s + wakeups/s.
    A single reading — `sample_state` runs several and medians them so one
    unlucky window (a shared-runner co-scheduled spike) can't skew the result.
    """
    check_alive(harness)
    pid = harness.pid
    start = ps_sample(pid)
    if start is None:
        sys.exit("error: app process not sampleable")
    power = start_powermetrics(seconds)

    rss_samples = []
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        time.sleep(1)
        check_alive(harness)
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


def sample_state(harness, seconds, samples):
    """Sample a state over `samples` back-to-back windows of `seconds` each and
    return the per-metric median. Splitting one long window into several short
    ones and taking the median keeps a single co-scheduled CPU spike on a shared
    CI runner from dominating the reading, at the same total wall-clock cost.
    With samples == 1 this is exactly one `sample_window` call (unchanged
    behavior for a local one-shot run)."""
    windows = []
    for i in range(samples):
        window = sample_window(harness, seconds)
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


def dump_diagnostics(harness, out_path):
    """On failure, surface what the app saw: its log lines and a screenshot
    (written next to the results for the CI diagnostics artifact)."""
    diag_dir = os.path.join(os.path.dirname(os.path.abspath(out_path)), "diagnostics")
    log_text = harness.dump_diagnostics(diag_dir)
    print("--- app log ---", flush=True)
    print(log_text, flush=True)


def enter_state(app, state):
    """Drive the window into a (possibly workload-prefixed) state. Full state
    machine: `minimized` isn't in the sampled set today (see IDLE_STATES /
    WORKLOAD_STATES) but is kept so a state can be re-added by name alone."""
    base = state.removeprefix("workload-")
    if base == "focused":
        # `restore` is idempotent when the window isn't minimized; harmless to
        # always send. `open` on the running bundle activates via
        # LaunchServices (user-intent level, unlike cooperative NSApp.activate).
        notify("restore")
        sh(["open", app])
        notify("activate")
    elif base == "unfocused":
        notify("restore")
        sh(["open", "-a", "Finder"])
    elif base == "minimized":
        notify("minimize")


def spawn_workload(harness, tabs):
    """Spawn `tabs` busy tabs (2×2 grid each) through the bundled CLI.

    Fails hard on any miss (HarnessError → diagnostics + exit in cmd_run):
    silently sampling a partial workload would compare unlike against unlike
    across runs.
    """
    # The socket answers `starting` until AppState attaches; by this point
    # the project is open so one poll round is usually enough.
    harness.wait_for_socket()

    print(f"spawning workload: {tabs} tabs x 4 panes", flush=True)
    for _ in range(tabs):
        harness.cli("tab", "new", "--run", WORKLOAD_COMMAND)
        harness.cli("grid", "2x2", "--run", WORKLOAD_COMMAND)
        # Pace the spawn burst: each tab is 4 shells + zmx sessions, and a
        # mass simultaneous spawn is its own pathology (PAM/memory storm),
        # not the steady state this measures.
        time.sleep(0.5)

    panes = harness.panes()
    expected = 1 + tabs * 4  # the project's original idle pane + the grids
    if len(panes) != expected:
        raise HarnessError(f"workload spawned {len(panes)} panes, expected {expected}")


def git_sha():
    sha = os.environ.get("GITHUB_SHA")
    if sha:
        return sha
    result = sh(["git", "rev-parse", "HEAD"])
    return result.stdout.strip() if result.returncode == 0 else "unknown"


def cmd_run(args):
    # Isolation (throwaway $HOME, MACTERM_BENCHMARK_DATA_DIR, ZMX_DIR) and the
    # LaunchServices launch + exact-pid-match recipe live in MactermHarness,
    # shared with the e2e suite; this function owns settling and sampling. The
    # home prefix keeps an aborted run's leftovers identifiable in /tmp.
    harness = MactermHarness(os.path.abspath(args.app), home_prefix="macterm-bench-home-")
    try:
        try:
            print(f"launching {harness.app}", flush=True)
            harness.launch()
            time.sleep(args.boot_settle)
            check_alive(harness)

            # Ask the app to open a project so a real shell + surface is on
            # screen (projects.json in the isolated data dir is the readiness
            # marker — see MactermHarness.open_project).
            harness.open_project()
            # Let the shell spawn and the initial render burst drain.
            time.sleep(args.boot_settle)

            results = {}
            for state in IDLE_STATES:
                enter_state(harness.app, state)
                time.sleep(args.settle)
                print(f"sampling {state}: {args.samples}x{args.seconds}s", flush=True)
                results[state] = sample_state(harness, args.seconds, args.samples)
                print(f"  {results[state]}", flush=True)

            if args.workload > 0:
                # Re-run under busy tabs so the numbers reflect an app doing real
                # terminal work, not an empty window. Spawn while focused (surfaces
                # need a window).
                enter_state(harness.app, "focused")
                spawn_workload(harness, args.workload)
                time.sleep(args.boot_settle)
                for state in WORKLOAD_STATES:
                    enter_state(harness.app, state)
                    time.sleep(args.settle)
                    print(f"sampling {state}: {args.samples}x{args.seconds}s", flush=True)
                    results[state] = sample_state(harness, args.seconds, args.samples)
                    print(f"  {results[state]}", flush=True)
        except HarnessError as exc:
            dump_diagnostics(harness, args.out)
            sys.exit(f"error: {exc}")
    finally:
        # Kills the workload's zmx sessions (their shells would otherwise
        # outlive the run), SIGKILLs the app (SIGTERM would hang on the
        # quit-confirmation dialog), and removes the throwaway home.
        harness.cleanup()

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

# Corroboration rule for the PR LABEL — a separate, stricter gate than the
# per-cell flag above. A single tripped cell still shows its 🔺/🔻 in the
# table (honest raw data), but labeling the PR requires the whole set of
# tripped cells to clear this bar. Two independent guards, because a genuine
# resource regression perturbs several correlated metrics at once while
# shared-runner noise trips one cell in isolation:
#   1. at least MIN_LABEL_CELLS cells trip (a lone outlier can't label), and
#   2. at least one tripped cell is a workload state — the regime that does
#      real terminal work. The idle baseline is the noisiest state, so idle
#      cells corroborate but can never carry a label by themselves.
MIN_LABEL_CELLS = 2


def is_workload_state(state):
    return state.startswith("workload-")


def should_label(entries):
    """Whether a set of tripped cells (all same direction) warrants a PR label
    under the corroboration rule: ≥ MIN_LABEL_CELLS cells, at least one under a
    workload state. Empty or idle-only sets never label."""
    return (
        len(entries) >= MIN_LABEL_CELLS
        and any(is_workload_state(e["state"]) for e in entries)
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


def pool_baselines(paths):
    """Pool several main-run baselines into one synthetic baseline: for each
    state/metric, the per-metric median across runs. A PR delta is one noisy
    sample against the reference, so a single-run reference doubles the noise
    in every cell — and one unlucky main run then mislabels every PR until the
    next push replaces it. The median (not the mean) keeps one such anomalous
    run from moving the reference at all, matching the per-state window median.
    Paths arrive newest-first (the workflow's index-prefixed filenames), so
    `commit` records the newest run for the report header."""
    runs = []
    for path in paths:
        with open(path) as f:
            runs.append(json.load(f))
    if len(runs) == 1:
        return runs[0]
    states = {}
    for state in STATES:
        per_run = [r["states"][state] for r in runs if r.get("states", {}).get(state)]
        if not per_run:
            continue  # e.g. workload states before main's baseline had them
        states[state] = {
            key: _median_or_none([s.get(key) for s in per_run])
            for key, *_ in METRICS
        }
    return {
        "commit": runs[0].get("commit", "unknown"),
        "runs": len(runs),
        "states": states,
    }


def cmd_report(args):
    with open(args.results) as f:
        current = json.load(f)
    baseline = pool_baselines(args.baseline) if args.baseline else None

    lines = ["## Window-state benchmark", ""]
    if baseline:
        baseline_runs = baseline.get("runs", 1)
        newest = baseline.get("commit", "unknown")[:9]
        if baseline_runs > 1:
            base_ref = f"main (median of {baseline_runs} runs)"
        else:
            base_ref = f"main@{newest}"
        lines += [
            f"| State | Metric | {base_ref} | this branch | Δ |",
            "|---|---|---:|---:|---:|",
        ]
    else:
        lines += ["| State | Metric | Value |", "|---|---|---:|"]

    regressions, improvements = [], []
    workload_missing_baseline = False
    for state in STATES:
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
        cell_lines = [
            f"- **{e['state']} — {e['metric']}**: "
            f"{fmt(e['base'], e['pattern'])} → {fmt(e['current'], e['pattern'])} ({e['pct']:+d}%)"
            for e in entries
        ]
        if should_label(entries):
            lines += [
                "",
                f"### {'⚠️' if verdict_line == 'regressed' else '🎉'} Labeled `{label_name}`",
                "",
                f"This PR is labeled `{label_name}` because ≥{MIN_LABEL_CELLS} metrics "
                f"{verdict_line} by ≥{THRESHOLD_PCT}% vs {base_ref} (beyond each metric's "
                "noise floor), at least one under workload:",
                "",
                *cell_lines,
            ]
        else:
            # Cells tripped their per-cell flag (they show 🔺/🔻 in the table)
            # but didn't clear the corroboration bar, so no label — say why, so
            # the arrows don't look like an unexplained near-miss.
            reason = (
                "only one metric moved"
                if len(entries) < MIN_LABEL_CELLS
                else "the moves were confined to the idle baseline"
            )
            lines += [
                "",
                f"_Not labeled `{label_name}`: {reason}. A label needs "
                f"≥{MIN_LABEL_CELLS} metrics past threshold with at least one under "
                f"workload. Flagged cells ({verdict_line}):_",
                "",
                *cell_lines,
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
        f"noise-dominated baseline aren't flagged ({gates}). The `benchmark:regression` / "
        f"`benchmark:improvement` label needs corroboration — ≥{MIN_LABEL_CELLS} flagged "
        "metrics in the same direction, at least one under workload — so a lone noisy cell "
        "shows its arrow here without tagging the PR._",
    ]
    if baseline is None:
        lines.append("")
        lines.append("_No main-branch baseline found; showing absolute values only._")
    elif baseline.get("runs", 1) > 1:
        lines.append("")
        lines.append(
            f"_The baseline column pools the last {baseline['runs']} successful "
            f"main runs (newest main@{newest}) as a per-metric median, so one "
            "anomalous main run can't skew the reference._"
        )
    if baseline is not None and workload_missing_baseline:
        lines.append("")
        lines.append(
            "_The `workload-*` states (busy tabs spawned via the `macterm` CLI) "
            "have no baseline yet — deltas for them appear once main's baseline "
            "includes a workload run._"
        )
    print("\n".join(lines))

    if args.verdict:
        # The booleans drive the PR label (benchmark-report.yml reads them), so
        # they apply the corroboration rule. The full cell lists ride along
        # unfiltered — every flagged cell, label-worthy or not — so the report
        # bundle keeps complete data.
        with open(args.verdict, "w") as f:
            json.dump({
                "regression": should_label(regressions),
                "improvement": should_label(improvements),
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
    report.add_argument(
        "--baseline", nargs="+", metavar="JSON",
        help="baseline results JSON(s) to compare against, newest first; several "
             "are pooled as a per-metric median so one anomalous main run can't "
             "skew the reference",
    )
    report.add_argument("--verdict", help="also write a labeling verdict JSON to this path")
    report.set_defaults(func=cmd_report)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
