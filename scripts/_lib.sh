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

# Map a marketing version to the version Sparkle ORDERS updates by
# (CFBundleVersion / <sparkle:version>). Display strings keep the human form via
# CFBundleShortVersionString / <sparkle:shortVersionString>.
#
#   1.8.0          -> 1.8.0.9999        (stable)
#   0.9.0-beta.1   -> 0.9.0.1           (beta)
#   1.24.2-tip.7   -> 1.24.2.9999.7     (tip)
#
# WHY, measured against the real SUStandardVersionComparator (not assumed): it
# splits on character-type boundaries and treats a `-` suffix as insignificant,
# so `0.9.0-beta.1 == 0.9.0 == 0.9.0-beta.2`. Feeding the raw beta string to
# Sparkle would mean beta->beta updates never appear ("You're up to date") and
# the eventual stable 0.9.0 never lands for testers. Encoding the beta number as
# a 4th component fixes both, and the 9999 sentinel keeps every beta of Z below
# stable Z while preserving X.Y.Z ordering across versions.
#
# The sentinel is NOT ".0": the comparator ranks `0.9.0.0.9 > 0.9.0`, so padding
# a stable version with fewer components than a beta inverts the order.
#
# TIP rides that same property from the other side. A tip build must rank ABOVE
# the stable release it is built on top of (it is strictly newer code) and below
# the NEXT stable, so it keeps the stable sentinel and appends the commit count
# since that stable tag as a 5th component: `1.24.2.9999.7 > 1.24.2.9999` and
# `< 1.25.0.9999`. Monotonic across a base bump too, because X.Y.Z only ever
# increases: the count restarting at 1 under a higher base still outranks any
# count under the lower one.
#
# This is deliberately NOT ghostty's scheme. Ghostty makes CFBundleVersion a
# bare `git rev-list --count HEAD` integer on BOTH channels, which is simpler
# and gets cross-channel ordering for free — but adopting it here would mean
# every already-installed Macterm (carrying `X.Y.Z.9999`) re-orders against a
# bare integer, and it throws away the semver ordering the stable and beta
# channels are already built and tested on. Extending the sentinel scheme costs
# one component and changes nothing for installed apps.
#
# Both scripts that emit a version MUST use this — a mismatch between the app's
# CFBundleVersion and the appcast's sparkle:version silently breaks updates.
sparkle_comparison_version() {
  local version="$1"
  if [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-beta\.([0-9]+)$ ]]; then
    printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  elif [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-tip\.([0-9]+)$ ]]; then
    printf '%s.9999.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '%s.9999\n' "$version"
  fi
}

# Which update channel a build belongs to, derived from its marketing version.
# Baked into the app bundle (see build.sh / Info.plist's MactermUpdateChannel)
# so a tip DMG downloaded by hand defaults to following tip.
#
# Beta deliberately reports `stable`: a beta's comparison version sorts BELOW
# the stable release of the same X.Y.Z, so a hand-installed beta still gets
# offered that stable release and can never dead-end. A TIP build sorts ABOVE
# it, so without this a hand-installed tip would see "You're up to date"
# forever — that asymmetry is the whole reason this function exists.
macterm_update_channel() {
  local version="$1"
  if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-tip\.[0-9]+$ ]]; then
    printf 'tip\n'
  else
    printf 'stable\n'
  fi
}

# Marketing version for a tip build of the current checkout: the newest STABLE
# release tag plus the number of commits on top of it — `1.24.2-tip.7`.
#
# Only `vX.Y.Z` tags are eligible as the base. `git describe` is not used and
# `--sort=-v:refname` alone is not enough: both would happily return the rolling
# `tip` tag itself (which release-tip.yml force-moves onto HEAD, so it is
# ALWAYS the closest tag) or a `vX.Y.Z-beta.N` prerelease tag. Either would make
# the version unparseable or non-monotonic.
#
# Requires full history and tags — the caller must check out with
# `fetch-depth: 0`.
macterm_tip_version() {
  local base_tag count
  base_tag=$(git tag --list 'v*' --sort=-v:refname \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
  if [[ -z "$base_tag" ]]; then
    echo "error: no vX.Y.Z tag found; cannot derive a tip version" >&2
    return 1
  fi
  # Commits reachable from HEAD but not from the base tag. Increments by exactly
  # one per commit on main, and a hotfix tag off a side branch still leaves it
  # increasing, so the resulting comparison version never goes backwards.
  count=$(git rev-list --count "${base_tag}..HEAD")
  printf '%s-tip.%s\n' "${base_tag#v}" "$count"
}
