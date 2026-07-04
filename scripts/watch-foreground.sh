#!/usr/bin/env bash
# Title-refresh test oracle.
#
# Macterm derives a tab's auto-title from the foreground process of the pane's
# tty (see ProcessInspector.runningProcessName). This watches that SAME source
# — the tty's foreground process group — straight from the kernel, and stamps
# every change. Run it next to Macterm to measure title-refresh lag:
#
#   1. In a Macterm tab, run:  tty      (prints e.g. /dev/ttys004)
#   2. In any other shell:      scripts/watch-foreground.sh /dev/ttys004
#   3. Back in the Macterm tab, launch/quit programs (hx, btop, sleep 5, ...).
#
# Each line here stamps WHEN the real foreground process changed. Compare that
# instant against WHEN the Macterm sidebar title visibly updates. A gap under
# ~1s is the adaptive cadence working (fast/idle tiers); a multi-second gap or
# a title that never catches up until you click is the bug to report.
#
# This is an oracle, not an assertion: it can't see Macterm's rendered title,
# so you read the sidebar yourself and compare timestamps.

set -euo pipefail

tty_path="${1:-}"
if [[ -z "$tty_path" ]]; then
  echo "usage: $0 <tty>   (run 'tty' inside the Macterm tab to get it)" >&2
  exit 2
fi
if [[ ! -e "$tty_path" ]]; then
  echo "error: $tty_path does not exist" >&2
  exit 2
fi

# The tty's foreground process group leader — the pid whose `comm` Macterm
# turns into the tab name. `ps -t <tty> -o ...=` with state '+' marks the
# foreground group; we take its command name.
foreground_comm() {
  # `-o stat,comm` then pick the row in the foreground group (stat contains '+').
  ps -t "${tty_path#/dev/}" -o stat=,comm= 2>/dev/null \
    | awk '$1 ~ /\+/ { $1=""; sub(/^ /,""); print; exit }'
}

echo "watching foreground process of $tty_path — Ctrl-C to stop"
echo "TIME              FOREGROUND"

last=""
while true; do
  now="$(foreground_comm || true)"
  if [[ "$now" != "$last" ]]; then
    printf '%s  %s\n' "$(date '+%H:%M:%S.%2N' 2>/dev/null || date '+%H:%M:%S')" "${now:-<none>}"
    last="$now"
  fi
  sleep 0.1
done
