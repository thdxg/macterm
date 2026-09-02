#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$PWD"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData"

# Ensure GhosttyKit + bundled resources (themes, shell-integration) are present
# before xcodegen resolves the folder references. Idempotent and fast when they
# already exist.
"$PROJECT_ROOT/scripts/setup.sh"

xcodegen generate --spec "$PROJECT_ROOT/project.yml" >/dev/null

xcodebuild \
  -project Macterm.xcodeproj \
  -scheme Macterm \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  build \
  | (xcbeautify --quiet 2>/dev/null || cat)

APP="$DERIVED_DATA/Build/Products/Debug/Macterm.app"

# `-n` forces a new instance of the bundle AT THIS PATH. Without it, `open`
# resolves through LaunchServices, which on a dev machine has many bundles
# registered under the same `com.thdxg.macterm.debug` ID — this checkout, every
# `.claude/worktrees/*` copy, stray `~/Library/Developer/Xcode/DerivedData`
# trees. It usually still picks the path given, but when a stale copy is already
# running it can reactivate THAT instance instead: observed launching a
# two-week-old worktree build, which even inherited the argv of the earlier
# launch record. The freshly built app then never runs, which reads as "the
# build worked but the app didn't start".
#
# Still LaunchServices rather than exec'ing Contents/MacOS/Macterm directly:
# launch-time activation counts as user intent, so the app becomes active and
# SwiftUI creates its window. A directly-exec'd app starts backgrounded and can
# be denied activation indefinitely, never getting a window — the same reason
# scripts/benchmark.py launches with `open -n`.
#
# Noninteractive runners commonly export `TERM=dumb` plus `NO_COLOR` for their
# own command logs. Let Ghostty replace TERM for panes, but do not leak that
# runner-only NO_COLOR into the GUI app: color-aware TUIs such as Claude then
# disable ANSI colors even though the terminal advertises truecolor. Preserve an
# explicitly requested NO_COLOR when a developer launches from a real terminal.
if [[ "${TERM:-}" == "dumb" && -n "${NO_COLOR+x}" ]]; then
  env -u NO_COLOR open -n "$APP"
else
  open -n "$APP"
fi
