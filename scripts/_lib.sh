#!/usr/bin/env bash
# Shared helpers for macterm scripts

# Spinner that runs a command with a loading message.
# Output is hidden on success. On failure, stderr is printed.
# Usage: run_step "Building release..." swift build -c release
run_step() {
  local msg="$1"
  shift
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0 pid logfile

  logfile=$(mktemp)
  "$@" > "$logfile" 2>&1 &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  %s %s" "${frames[i++ % ${#frames[@]}]}" "$msg"
    sleep 0.08
  done

  # Capture the child's exit status errexit-safely: a bare `wait "$pid"`
  # followed by `$?` would trip `set -e` on a nonzero status BEFORE the
  # log-printing failure branch below runs, so the diagnostic never appears.
  local status=0
  wait "$pid" || status=$?
  if [[ $status -eq 0 ]]; then
    printf "\r  ✓ %s\n" "$msg"
  else
    printf "\r  ✗ %s\n" "$msg"
    cat "$logfile"
  fi
  rm -f "$logfile"
  [[ $status -eq 0 ]] || exit $status
}

# Print a step header without spinner (for interactive commands).
step() {
  printf "  → %s\n" "$1"
}

# Map a marketing version to the 4-component version Sparkle ORDERS updates by
# (CFBundleVersion / <sparkle:version>). Display strings keep the human form via
# CFBundleShortVersionString / <sparkle:shortVersionString>.
#
#   1.8.0         -> 1.8.0.9999   (stable)
#   0.9.0-beta.1  -> 0.9.0.1      (beta)
#
# WHY, measured against the real SUStandardVersionComparator (not assumed): it
# splits on character-type boundaries and treats a `-` suffix as insignificant,
# so `0.9.0-beta.1 == 0.9.0 == 0.9.0-beta.2`. Feeding the raw beta string to
# Sparkle would mean beta→beta updates never appear ("You're up to date") and
# the eventual stable 0.9.0 never lands for testers. Encoding the beta number as
# a 4th component fixes both, and the 9999 sentinel keeps every beta of Z below
# stable Z while preserving X.Y.Z ordering across versions.
#
# The sentinel is NOT ".0": the comparator ranks `0.9.0.0.9 > 0.9.0`, so padding
# a stable version with fewer components than a beta inverts the order.
#
# Both scripts that emit a version MUST use this — a mismatch between the app's
# CFBundleVersion and the appcast's sparkle:version silently breaks updates.
sparkle_comparison_version() {
  local version="$1"
  if [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-beta\.([0-9]+)$ ]]; then
    printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '%s.9999\n' "$version"
  fi
}
