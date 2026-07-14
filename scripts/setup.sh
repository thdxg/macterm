#!/usr/bin/env bash
set -euo pipefail

FORK_REPO="thdxg/ghostty"
ZMX_REPO="thdxg/zmx"
XCFRAMEWORK_DIR="GhosttyKit.xcframework"
# Marker for the downloaded upstream resources. The tarball mirrors a real
# Ghostty.app Resources layout: ghostty/{themes,shell-integration} plus a
# sibling terminfo/. All come from the tarball — nothing is committed — so its
# presence signals the download ran. Keyed on terminfo/ so checkouts predating
# the terminfo bundling (or the flat-layout interim) re-download it.
RESOURCES_MARKER="Macterm/Resources/terminfo"
# Prebuilt zmx session multiplexer (session persistence). Built by thdxg/zmx CI
# and downloaded here, mirroring GhosttyKit — never compiled locally (zig).
# Embedded into the bundle at Contents/Resources/zmx/zmx by embed-zmx.sh.
ZMX_BIN="Macterm/Resources/zmx/zmx"

need_xcframework=true
need_resources=true
need_zmx=true
[[ -d "$XCFRAMEWORK_DIR" ]] && need_xcframework=false
[[ -d "$RESOURCES_MARKER" ]] && need_resources=false
[[ -x "$ZMX_BIN" ]] && need_zmx=false

if ! $need_xcframework && ! $need_resources && ! $need_zmx; then
  echo "GhosttyKit, resources, and zmx already present"
  exit 0
fi

LATEST_TAG=$(gh release list --repo "$FORK_REPO" --limit 1 --json tagName -q ".[0].tagName")
if [[ -z "$LATEST_TAG" ]]; then
  echo "Error: No releases found" >&2
  exit 1
fi

if $need_xcframework; then
  gh release download "$LATEST_TAG" --pattern "GhosttyKit.xcframework.tar.gz" --repo "$FORK_REPO"
  tar xzf GhosttyKit.xcframework.tar.gz
  rm GhosttyKit.xcframework.tar.gz
fi

# Fork-drift warning (macterm#168). The thdxg/ghostty fork ships prebuilt
# GhosttyKit; a past sync-upstream bug silently reverted ~190 upstream files to
# stale versions while looking current, shipping an old libghostty that
# resurfaced macterm#112. The fork's `sync-upstream.yml` is now revert-proof and
# an `assert-no-drift.yml` guards it fork-side — but a checkout can still be
# holding a GhosttyKit whose UPSTREAM BASE is old (an artifact downloaded before
# a fix landed, or the fork having stopped syncing). This surfaces that here.
#
# libghostty bakes its `build_config.version` as `<semver>-<branch>-+<sha>` into
# the static archive, where <sha> is the FORK commit it was built from. That
# commit's PARENT is the pristine upstream base (the fork = upstream + 1 squash
# commit). We compare that base's date against upstream HEAD's. Strictly
# advisory: any failure to determine it (no gh, offline, unparseable, rate
# limited) is silently skipped so setup always completes.
warn_if_ghosttykit_stale() {
  local stale_days="${MACTERM_GHOSTTYKIT_MAX_AGE_DAYS:-14}"
  local lib="$XCFRAMEWORK_DIR/macos-arm64_x86_64/ghostty-internal.a"
  [[ -f "$lib" ]] || return 0
  command -v strings >/dev/null 2>&1 || return 0
  command -v gh >/dev/null 2>&1 || return 0

  local ver sha parent base_epoch head_epoch age_days
  ver="$(strings "$lib" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[a-z]+-?\+[0-9a-f]{7,}' | head -1)" || return 0
  [[ -n "$ver" ]] || return 0
  sha="$(printf '%s' "$ver" | grep -oE '\+[0-9a-f]{7,}' | tr -d '+')" || return 0
  [[ -n "$sha" ]] || return 0

  # The fork commit's parent = the upstream base it was rebuilt onto.
  parent="$(gh api "repos/${FORK_REPO}/commits/${sha}" --jq '.parents[0].sha' 2>/dev/null)" || return 0
  [[ -n "$parent" && "$parent" != "null" ]] || return 0
  base_epoch="$(gh api "repos/ghostty-org/ghostty/commits/${parent}" --jq '.commit.committer.date' 2>/dev/null | to_epoch)" || return 0
  head_epoch="$(gh api "repos/ghostty-org/ghostty/commits/main" --jq '.commit.committer.date' 2>/dev/null | to_epoch)" || return 0
  [[ -n "$base_epoch" && -n "$head_epoch" ]] || return 0

  age_days=$(( (head_epoch - base_epoch) / 86400 ))
  if (( age_days > stale_days )); then
    echo "" >&2
    echo "warning: bundled GhosttyKit ($ver) was built from an upstream base ~${age_days} days" >&2
    echo "         behind ghostty-org/ghostty HEAD (threshold ${stale_days}d). It may be missing" >&2
    echo "         upstream fixes (this is the class of staleness behind macterm#112)." >&2
    echo "         Refresh: rm -rf $XCFRAMEWORK_DIR && ./scripts/setup.sh" >&2
    echo "         If the fork itself is stale, check thdxg/ghostty's Assert No Drift workflow." >&2
    echo "" >&2
  fi
}

# Portable ISO-8601 → epoch (GNU date vs BSD/macOS date differ on flags).
to_epoch() {
  local ts; read -r ts || return 1
  [[ -n "$ts" ]] || return 1
  date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" "+%s" 2>/dev/null \
    || date -d "$ts" "+%s" 2>/dev/null \
    || return 1
}

warn_if_ghosttykit_stale || true

if $need_resources; then
  # Bundled ghostty resources so TERM=xterm-ghostty, named themes (Rose Pine,
  # etc.), and shell integration all resolve without a separate Ghostty.app
  # install. The tarball mirrors a real Ghostty.app Resources layout:
  # ghostty/{themes,shell-integration} plus a SIBLING terminfo/. libghostty
  # derives TERMINFO as dirname(GHOSTTY_RESOURCES_DIR)/terminfo, so terminfo
  # must sit beside the ghostty/ dir, not inside it. Extracted into
  # Macterm/Resources/ (all gitignored — none committed). Clear any prior
  # extraction first so a stale flat layout can't linger beside the new one.
  gh release download "$LATEST_TAG" --pattern "ghostty-resources.tar.gz" --repo "$FORK_REPO"
  rm -rf Macterm/Resources/ghostty Macterm/Resources/terminfo \
    Macterm/Resources/themes Macterm/Resources/shell-integration
  mkdir -p Macterm/Resources
  tar xzf ghostty-resources.tar.gz -C Macterm/Resources
  rm ghostty-resources.tar.gz
fi

if $need_zmx; then
  # Prebuilt universal (arm64+x86_64) zmx binary from the thdxg/zmx release.
  # Universal so it execs on both Apple Silicon and Intel, matching Macterm's
  # universal app build. Shipped as a tarball (preserves the executable bit
  # through the GitHub asset round-trip) holding a single `zmx` binary;
  # extracted to Macterm/Resources/zmx/zmx (gitignored).
  ZMX_TAG=$(gh release list --repo "$ZMX_REPO" --limit 1 --json tagName -q ".[0].tagName")
  if [[ -z "$ZMX_TAG" ]]; then
    echo "Error: No zmx releases found in $ZMX_REPO" >&2
    exit 1
  fi
  gh release download "$ZMX_TAG" --pattern "zmx-universal-macos.tar.gz" --repo "$ZMX_REPO"
  rm -rf Macterm/Resources/zmx
  mkdir -p Macterm/Resources/zmx
  tar xzf zmx-universal-macos.tar.gz -C Macterm/Resources/zmx
  chmod +x Macterm/Resources/zmx/zmx
  rm zmx-universal-macos.tar.gz
fi
