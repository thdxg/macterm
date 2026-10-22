#!/usr/bin/env bash
# Start a built Macterm on this Mac and check that it runs. CI builds the app
# once with the pinned Xcode on the newest macOS, then runs this on older
# macOS runners (test.yml, "Older macOS"), because no test suite runs there:
#
#   - the app starts and its control socket answers `status`, so an SDK or a
#     Swift runtime from the newer Xcode did not break the launch;
#   - on macOS 26 and later, the app paints an adaptive icon by itself, so the
#     private renderer (macterm-icon-renderer) still works on this macOS;
#   - before macOS 26, the app does not try.
#
#   scripts/older-macos-smoke.sh "<path to Macterm.app>"
#
# The instance is isolated: a throwaway HOME, data folder and zmx folder. It
# runs without MACTERM_BENCHMARK, which would turn the adaptive icon off.
set -euo pipefail

APP="${1:?usage: older-macos-smoke.sh <Macterm.app>}"
[ -d "$APP" ] || { echo "error: no app at $APP" >&2; exit 1; }
CLI="$APP/Contents/Resources/bin/macterm"
BUNDLE_ID="$(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier)"
VERSION="$(sw_vers -productVersion)"
MAJOR="${VERSION%%.*}"

# A short path: the control socket's path must fit in 104 bytes.
ROOT="$(mktemp -d /tmp/mt-smoke.XXXX)"
mkdir -p "$ROOT/home/.config" "$ROOT/data" "$ROOT/zmx"
SOCKET="$ROOT/data/control.sock"
ICONS="$ROOT/data/AdaptiveIcon"
touch "$ROOT/started"   # crash reports newer than this are ours

say() { printf '== %s\n' "$*"; }
fail() {
  printf 'error: %s\n' "$*" >&2
  # A crash at launch leaves a report, and its first lines name the cause.
  local report
  report="$(find "$HOME/Library/Logs/DiagnosticReports" -name '*Macterm*' -newer "$ROOT/started" 2>/dev/null | head -1 || true)"
  if [ -n "$report" ]; then
    echo "--- $report" >&2
    head -60 "$report" >&2
  fi
  exit 1
}
quit() {
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do pgrep -f "$APP/Contents/MacOS/" >/dev/null || return 0; sleep 0.5; done
  pkill -f "$APP/Contents/MacOS/" || true
}
trap quit EXIT

say "macOS $VERSION, $(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString) ($BUNDLE_ID)"
open -n \
  --env HOME="$ROOT/home" \
  --env XDG_CONFIG_HOME="$ROOT/home/.config" \
  --env ZMX_DIR="$ROOT/zmx" \
  --env MACTERM_BENCHMARK_DATA_DIR="$ROOT/data" \
  "$APP"

answered=false
for _ in $(seq 1 120); do
  if "$CLI" status --socket "$SOCKET" >/dev/null 2>&1; then answered=true; break; fi
  pgrep -f "$APP/Contents/MacOS/" >/dev/null || fail "the app is not running any more"
  sleep 0.5
done
$answered || fail "the control socket did not answer in 60 s"
say "started: $("$CLI" status --socket "$SOCKET")"

if [ "$MAJOR" -ge 26 ]; then
  icon=""
  for _ in $(seq 1 120); do
    icon="$(find "$ICONS" -name '*.png' 2>/dev/null | head -1 || true)"
    [ -n "$icon" ] && break
    sleep 0.5
  done
  if [ -z "$icon" ]; then
    # Run the helper by hand, so its own error is in the log.
    catalog="$APP/Contents/Resources/Assets.car"
    request='{"catalogPath":"'"$catalog"'","iconName":"AppIcon","appearance":"dark","backgroundTop":{"red":0.1,"green":0.1,"blue":0.12},"backgroundBottom":{"red":0.07,"green":0.07,"blue":0.08},"layers":[{"red":0.41,"green":0.43,"blue":0.49},{"red":0.6,"green":0.62,"blue":0.68},{"red":0.8,"green":0.81,"blue":0.82},{"red":0.8,"green":0.81,"blue":0.82}],"pixels":256}'
    "$APP/Contents/Helpers/macterm-icon-renderer" "$request" >/dev/null || echo "the helper exited with $?" >&2
    fail "macOS $VERSION: the app painted no adaptive icon in 60 s"
  fi
  size="$(sips -g pixelWidth -g pixelHeight "$icon" | awk '/pixel/ { print $2 }' | paste -sd x -)"
  [ "$size" = "1024x1024" ] || fail "the adaptive icon is $size, not 1024x1024"
  say "adaptive icon painted: $(basename "$icon") $size"
else
  sleep 5
  [ ! -d "$ICONS" ] || fail "macOS $VERSION: the app tried an adaptive icon, which needs macOS 26"
  say "no adaptive icon before macOS 26, as expected"
fi

pgrep -f "$APP/Contents/MacOS/" >/dev/null || fail "the app stopped during the check"
say "ok"
