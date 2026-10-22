#!/usr/bin/env bash
# Start a built Macterm on this Mac and check that it runs. CI builds the
# Release app once with the pinned Xcode on the newest macOS ("Release build"),
# then runs this on older macOS runners (test.yml, "Smoke"), because no test
# suite runs there:
#
#   - the app starts and its control socket answers `status`, so an SDK or a
#     Swift runtime from the newer Xcode did not break the launch;
#   - the app is a terminal: a new tab gets a shell through the bundled zmx,
#     a command typed into it runs, and its output reads back through
#     libghostty. A split does the same in a second pane;
#   - on macOS 26 and later, the app paints an adaptive icon by itself, so the
#     private renderer (macterm-icon-renderer) still works on this macOS;
#   - before macOS 26, the app does not try;
#   - nothing that the run started (the app, zmx, the icon helper) left a
#     crash report.
#
#   scripts/older-macos-smoke.sh "<path to Macterm.app>"
#
# The instance is isolated: a throwaway HOME, data folder and zmx folder. It
# runs without MACTERM_BENCHMARK, which would turn the adaptive icon off.
# UserDefaults is NOT isolated (cfprefsd ignores HOME): on a developer Mac the
# run reads and writes the real defaults domain of that build.
set -euo pipefail

APP="${1:?usage: older-macos-smoke.sh <Macterm.app>}"
[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }
# Absolute: `defaults read` takes a relative path for a domain name, and the
# process match below needs the full path.
APP="$(cd "$(dirname "$APP")" && pwd -P)/$(basename "$APP")"
CLI="$APP/Contents/Resources/bin/macterm"
EXECUTABLE="$APP/Contents/MacOS/$(defaults read "$APP/Contents/Info.plist" CFBundleExecutable)"
VERSION="$(sw_vers -productVersion)"
MAJOR="${VERSION%%.*}"

# A short path: the control socket's path must fit in 104 bytes.
ROOT="$(mktemp -d /tmp/mt-smoke.XXXX)"
mkdir -p "$ROOT/home/.config" "$ROOT/data" "$ROOT/zmx"
SOCKET="$ROOT/data/control.sock"
ICONS="$ROOT/data/AdaptiveIcon"
touch "$ROOT/started"   # crash reports newer than this are ours
PID=""

say() { printf '== %s\n' "$*"; }
# Crash reports from this run: the app, zmx or the icon helper.
crash_reports() {
  find "$HOME/Library/Logs/DiagnosticReports" -newer "$ROOT/started" \
    \( -name 'Macterm*' -o -name 'zmx*' -o -name 'macterm-icon-renderer*' \) 2>/dev/null || true
}
fail() {
  printf 'error: %s\n' "$*" >&2
  # A crash leaves a report, and its first lines name the cause.
  local report
  for report in $(crash_reports); do
    echo "--- $report" >&2
    head -60 "$report" >&2
  done
  exit 1
}

# Only the process that this run started. A Macterm that the developer runs,
# or another copy of the same build, must never be quit or killed. `pgrep -f`
# reads the path as a pattern, so check each command line exactly.
pids_of_app() {
  local pid
  for pid in $(pgrep -f -- "$EXECUTABLE" || true); do
    [ "$(ps -p "$pid" -o command= 2>/dev/null | cut -c "1-${#EXECUTABLE}")" = "$EXECUTABLE" ] && echo "$pid"
  done
  return 0
}
alive() { [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; }

# `--socket` goes after the subcommand, and never after `--`.
cli() { "$CLI" "$@" --socket "$SOCKET"; }
field() { plutil -extract "$1" raw -o - - 2>/dev/null; }

# The zmx sessions outlive the app by design, so kill this run's sessions
# while the app can still reach them. Then SIGKILL the app: SIGTERM waits on
# the quit confirmation for a running shell.
teardown() {
  if alive; then
    # Read every name first: each kill changes the list.
    local list count i names=""
    list="$(cli session list --json 2>/dev/null || true)"
    count="$(printf '%s' "$list" | field sessions || echo 0)"
    for i in $(seq 0 $((count - 1))); do
      names="$names $(printf '%s' "$list" | field "sessions.$i.name" || true)"
    done
    for name in $names; do cli session kill "$name" >/dev/null 2>&1 || true; done
  fi
  if [ -n "$PID" ]; then kill -KILL "$PID" 2>/dev/null || true; fi
}
trap teardown EXIT

# wait_until <seconds> <what> <command…>: run the command every 0.5 s until it
# succeeds. Fails at once if the app stops.
wait_until() {
  local seconds="$1" what="$2" i
  shift 2
  for i in $(seq 1 $((seconds * 2))); do
    "$@" && return 0
    alive || fail "the app stopped while waiting for $what"
    sleep 0.5
  done
  return 1
}

say "macOS $VERSION, $(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString) ($(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier))"
before=" $(pids_of_app | tr '\n' ' ')"
open -n \
  --env HOME="$ROOT/home" \
  --env XDG_CONFIG_HOME="$ROOT/home/.config" \
  --env ZMX_DIR="$ROOT/zmx" \
  --env MACTERM_BENCHMARK_DATA_DIR="$ROOT/data" \
  "$APP"
for _ in $(seq 1 20); do
  for pid in $(pids_of_app); do
    case "$before" in *" $pid "*) ;; *) PID="$pid" ;; esac
  done
  [ -n "$PID" ] && break
  sleep 0.5
done
[ -n "$PID" ] || fail "the app process did not appear"

answers() { cli status >/dev/null 2>&1; }
wait_until 60 "the control socket" answers || fail "the control socket did not answer in 60 s"
say "started: $(cli status)"

# ── A terminal ──────────────────────────────────────────────────────────────

# A project of its own. A fresh install seeds one, but a defaults domain that
# says "already seeded" (a developer's Mac) has none, and `tab new` needs one.
cli project create "$ROOT/home" --name smoke --select >/dev/null || fail "project create failed"

dump() { cli pane dump --pane "$1" --json 2>/dev/null | field dump.text || true; }
prompt_drawn() { [ -n "$(dump "$1" | tr -d '[:space:]')" ]; }
shows() { dump "$1" | grep -qF -- "$2"; }

# roundtrip <pane> <label>: wait for the prompt, type a command, read its
# output back. The marker is assembled at run time, so the typed line
# (`printf smoke-%s <nonce>`) never matches it.
roundtrip() {
  local pane="$1" label="$2" nonce="$RANDOM$RANDOM"
  wait_until 60 "the $label shell prompt" prompt_drawn "$pane" \
    || fail "the $label pane drew no shell prompt in 60 s"
  "$CLI" pane run --socket "$SOCKET" --pane "$pane" -- "printf smoke-%s $nonce" >/dev/null \
    || fail "pane run failed in the $label pane"
  wait_until 30 "the $label output" shows "$pane" "smoke-$nonce" \
    || fail "the $label pane did not show its output in 30 s. It shows:
$(dump "$pane")"
  say "$label pane: a shell ran a command"
}

tab="$(cli tab new --json | field tabs.0.id)" || fail "tab new failed"
pane_in_tab() { cli pane list --tab "$tab" --json 2>/dev/null | field panes.0.id; }
wait_until 30 "the new tab's pane" pane_in_tab >/dev/null || fail "the new tab has no pane"
pane="$(pane_in_tab)"
roundtrip "$pane" "first"

split="$(cli pane split --pane "$pane" --direction right --json | field panes.0.id)" \
  || fail "pane split failed"
roundtrip "$split" "split"

# ── The adaptive icon ───────────────────────────────────────────────────────

if [ "$MAJOR" -ge 26 ]; then
  icon_painted() { [ -n "$(find "$ICONS" -name '*.png' 2>/dev/null | head -1 || true)" ]; }
  if ! wait_until 60 "the adaptive icon" icon_painted; then
    # Run the helper by hand, so its own error is in the log.
    catalog="$APP/Contents/Resources/Assets.car"
    request='{"catalogPath":"'"$catalog"'","iconName":"AppIcon","appearance":"dark","backgroundTop":{"red":0.1,"green":0.1,"blue":0.12},"backgroundBottom":{"red":0.07,"green":0.07,"blue":0.08},"layers":[{"red":0.41,"green":0.43,"blue":0.49},{"red":0.6,"green":0.62,"blue":0.68},{"red":0.8,"green":0.81,"blue":0.82},{"red":0.8,"green":0.81,"blue":0.82}],"pixels":256}'
    "$APP/Contents/Helpers/macterm-icon-renderer" "$request" >/dev/null || echo "the helper exited with $?" >&2
    fail "macOS $VERSION: the app painted no adaptive icon in 60 s"
  fi
  icon="$(find "$ICONS" -name '*.png' | head -1)"
  size="$(sips -g pixelWidth -g pixelHeight "$icon" | awk '/pixel/ { print $2 }' | paste -sd x -)"
  [ "$size" = "1024x1024" ] || fail "the adaptive icon is $size, not 1024x1024"
  say "adaptive icon painted: $(basename "$icon") $size"
else
  sleep 5
  [ ! -d "$ICONS" ] || fail "macOS $VERSION: the app tried an adaptive icon, which needs macOS 26"
  say "no adaptive icon before macOS 26, as expected"
fi

# ── Nothing crashed ─────────────────────────────────────────────────────────

alive || fail "the app stopped during the check"
# ReportCrash writes a report a short time after the crash.
sleep 3
[ -z "$(crash_reports)" ] || fail "a crash report appeared during the run"
say "ok"
