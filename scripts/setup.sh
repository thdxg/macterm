#!/usr/bin/env bash
set -euo pipefail

FORK_REPO="thdxg/ghostty"
ZMX_REPO="thdxg/zmx"
XCFRAMEWORK_DIR="GhosttyKit.xcframework"
# The pinned thdxg/ghostty release supplying BOTH GhosttyKit and the bundled
# ghostty resources (one release, two assets).
#
# This used to track `latest`, and thdxg/ghostty publishes a build-YYYY-MM-DD
# release EVERY day — so every Macterm build, tagged releases included, silently
# picked up whatever libghostty landed that morning. Two builds of the same
# Macterm commit could ship different terminal cores, and a release could carry
# an upstream change nobody had run. Bumping the terminal core is now an
# explicit, reviewable commit instead of a side effect of the calendar.
#
# Set GHOSTTYKIT_TAG to another tag (or `latest`) to try one without committing:
#   GHOSTTYKIT_TAG=latest mise run setup
# `pinned-2026-08-26` is a byte-identical, immutable copy of build-2026-08-26
# (upstream 2026-08-25 + downstream patches 0001–0004). The daily tag itself
# couldn't be pinned on its own UTC day: any same-day push to the fork's main —
# including the nightly sync — deletes and recreates it with different bytes,
# the exact asset-swap-under-a-pin hazard documented in AGENTS.md. The next
# ordinary bump (a past-day daily tag, immutable by then) retires this one.
GHOSTTYKIT_TAG="${GHOSTTYKIT_TAG:-build-2026-08-31}"
# Which tag the on-disk fork artifacts actually came from. Without this the
# presence checks below would keep a stale copy forever after a pin bump — the
# same silent-staleness trap that makes symlinking these artifacts a bad idea.
#
# Written ONLY by a run that downloaded BOTH fork artifacts (see the stamp block
# at the bottom). It is a single scalar, so it can only honestly describe a tree
# where both came from one release. Gating it on the two dirs merely EXISTING
# laundered a stale tree as pinned: a run that downloaded neither (say only zmx
# was missing) or just one of the two still wrote the current pin over whatever
# was already there, and from then on every run saw a stamp agreeing with
# GHOSTTYKIT_TAG and never refreshed. A real tree hit this — resources from one
# release beside a framework from another, stamped as if both were pinned.
#
# So absent means "provenance unknown", NOT "matches the pin". It still forces
# no re-download (introducing the pin churned nobody, and see
# warn_unstamped_artifacts for why refreshing here is worse than warning), but
# such a tree is a dead end for the refresh: `tag_changed` needs a stamp to
# compare against, so an unstamped tree never adopts a bumped pin on its own.
# That is what the warning is for.
TAG_STAMP=".ghosttykit-tag"
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
# Does the xcframework rooted at $1 expose the output-activity ABI Macterm's
# activity indicator requires? Globs the slice directories rather than naming
# one: the macOS slice's name is chosen by the fork's build (today
# `macos-arm64_x86_64`), and hardcoding it would make a renamed slice report
# "missing ABI" forever — a silent re-download on every single setup run with
# no indication why.
has_output_activity_action() {
  local root="$1" header
  for header in "$root"/*/Headers/ghostty.h; do
    [[ -f "$header" ]] || continue
    if grep -q 'GHOSTTY_ACTION_OUTPUT_ACTIVITY' "$header"; then return 0; fi
  done
  return 1
}

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
    # NOT `rm -rf && setup.sh` — the release is pinned, so that just re-downloads
    # the same tag. The pin itself has to move.
    echo "         Fix: bump GHOSTTYKIT_TAG in scripts/setup.sh (currently" >&2
    echo "         $GHOSTTY_TAG) to a newer $FORK_REPO release, then re-run setup." >&2
    echo "         The weekly bump-ghosttykit.yml workflow normally opens that PR;" >&2
    echo "         if this is firing, check whether those runs are failing." >&2
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

# Resolve the pin up front: the presence checks below need it to spot a bumped
# pin. A literal tag costs nothing; only an explicit `latest` hits the network.
if [[ "$GHOSTTYKIT_TAG" == "latest" ]]; then
  GHOSTTY_TAG=$(gh release list --repo "$FORK_REPO" --limit 1 --json tagName -q ".[0].tagName")
  if [[ -z "$GHOSTTY_TAG" ]]; then
    echo "Error: No releases found in $FORK_REPO" >&2
    exit 1
  fi
  echo "GHOSTTYKIT_TAG=latest resolved to $GHOSTTY_TAG"
else
  GHOSTTY_TAG="$GHOSTTYKIT_TAG"
fi

# Fork artifacts on disk that no run ever stamped: they came from a release
# nobody recorded, and nothing here will refresh them, since spotting a bumped
# pin means comparing against a stamp. Deliberately advisory rather than a forced
# re-download — CI restores exactly this state from its GhosttyKit cache and
# already records provenance in that cache's key (it hashes this script), so
# refreshing on a missing stamp would re-download on every hit for no gain.
# Silence is the one option ruled out: it is what let a stale core look pinned.
warn_unstamped_artifacts() {
  # `:-` because the definition precedes the assignment: under `set -u` an
  # earlier call site added later would otherwise abort setup outright.
  [[ -z "${stamped_tag:-}" ]] || return 0
  [[ -d "$XCFRAMEWORK_DIR" || -d "$RESOURCES_MARKER" ]] || return 0
  echo "" >&2
  echo "note: the GhosttyKit/resources on disk carry no tag stamp, so which release" >&2
  echo "      they came from is unknown — possibly two different ones. Nothing will" >&2
  echo "      refresh them: a bumped pin is detected by disagreeing with a stamp, so" >&2
  echo "      an unstamped tree keeps building against the core it already has." >&2
  echo "      To install $GHOSTTY_TAG for certain:" >&2
  echo "        rm -rf $XCFRAMEWORK_DIR $RESOURCES_MARKER && ./scripts/setup.sh" >&2
  echo "" >&2
}

stamped_tag=""
[[ -f "$TAG_STAMP" ]] && stamped_tag=$(cat "$TAG_STAMP")
# Only a stamp that exists AND disagrees forces a refresh (see $TAG_STAMP).
tag_changed=false
if [[ -n "$stamped_tag" && "$stamped_tag" != "$GHOSTTY_TAG" ]]; then
  tag_changed=true
  echo "Pinned GhosttyKit release changed ($stamped_tag -> $GHOSTTY_TAG); refreshing"
fi

need_xcframework=true
need_resources=true
need_zmx=true
if [[ -d "$XCFRAMEWORK_DIR" ]] && ! $tag_changed; then
  if has_output_activity_action "$XCFRAMEWORK_DIR"; then
    need_xcframework=false
  else
    # Deliberately NOT removed here. The replacement is downloaded and validated
    # in a scratch dir below and only swapped in once it's known good, so a
    # release that also lacks the ABI leaves this (older, but working) framework
    # alone instead of stranding the checkout with no framework at all.
    echo "Existing GhosttyKit lacks GHOSTTY_ACTION_OUTPUT_ACTIVITY; refreshing it"
  fi
fi
# Resources ship in the same release as the xcframework, so they move together —
# a pin bump must not leave a new libghostty beside the old release's terminfo.
if [[ -d "$RESOURCES_MARKER" ]] && ! $tag_changed; then
  need_resources=false
fi
[[ -x "$ZMX_BIN" ]] && need_zmx=false

if ! $need_xcframework && ! $need_resources && ! $need_zmx; then
  echo "GhosttyKit, resources, and zmx already present"
  # This is the path a settled checkout takes every time, so it is also where an
  # unstamped tree would otherwise sit unnoticed forever.
  warn_unstamped_artifacts
  # Warn on the no-op path too. This used to run only after a download, which
  # made it dead code on a settled checkout — tolerable while the tag was
  # `latest` (any fresh checkout pulled current anyway), but now that nothing
  # ever pulls current on its own this warning is the whole safety net for a pin
  # left to rot. `bump-ghosttykit.yml` is the routine path; this covers a
  # checkout whose scheduled bump has been failing or ignored.
  warn_if_ghosttykit_stale || true
  exit 0
fi

if $need_xcframework; then
  # Download and validate into a scratch dir, then swap. Validating in place
  # would mean a release without the ABI leaves the tree with no framework at
  # all (the pre-existing one already deleted, the new one rejected), and every
  # re-run repeats the failure. Staging keeps a bad release a no-op.
  staging="$(mktemp -d "${TMPDIR:-/tmp}/macterm-ghosttykit.XXXXXX")"
  trap 'rm -rf "$staging"' EXIT
  gh release download "$GHOSTTY_TAG" --pattern "GhosttyKit.xcframework.tar.gz" --repo "$FORK_REPO" --dir "$staging"
  tar xzf "$staging/GhosttyKit.xcframework.tar.gz" -C "$staging"
  if ! has_output_activity_action "$staging/$XCFRAMEWORK_DIR"; then
    echo "Error: GhosttyKit from $GHOSTTY_TAG lacks GHOSTTY_ACTION_OUTPUT_ACTIVITY" >&2
    echo "The thdxg/ghostty output-activity downstream patch must be released first." >&2
    echo "" >&2
    echo "Note: Macterm has required this ABI since the reliable-activity-detection" >&2
    echo "change (see the GhosttyKit note in AGENTS.md). A checkout from BEFORE that" >&2
    echo "commit — e.g. while bisecting — does not need it: extract a GhosttyKit from" >&2
    echo "a $FORK_REPO release contemporary with that commit instead of running setup." >&2
    echo "Any existing $XCFRAMEWORK_DIR was left untouched." >&2
    exit 1
  fi
  rm -rf "$XCFRAMEWORK_DIR"
  mv "$staging/$XCFRAMEWORK_DIR" "$XCFRAMEWORK_DIR"
  rm -rf "$staging"
  trap - EXIT
fi
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
  gh release download "$GHOSTTY_TAG" --pattern "ghostty-resources.tar.gz" --repo "$FORK_REPO"
  rm -rf Macterm/Resources/ghostty Macterm/Resources/terminfo \
    Macterm/Resources/themes Macterm/Resources/shell-integration
  mkdir -p Macterm/Resources
  tar xzf ghostty-resources.tar.gz -C Macterm/Resources
  rm ghostty-resources.tar.gz
fi

# Stamp last, and only for what THIS run actually installed — both need_* flags,
# not just the dirs existing, or the stamp launders artifacts it never fetched
# (see $TAG_STAMP). A pin bump sets both flags, so the case the stamp exists for
# still records itself; a run that replaced only one of the two leaves the tree
# honestly unstamped rather than claiming a release only half of it came from.
#
# The dir checks stay as belt-and-braces for the property that a partial setup
# never stamps: a network failure between the two downloads aborts under `set -e`
# long before here, and this keeps that true if a future edit ever softens it.
# Any `exit 1` above likewise leaves the old stamp — and the refresh — in place.
if $need_xcframework && $need_resources &&
  [[ -d "$XCFRAMEWORK_DIR" && -d "$RESOURCES_MARKER" ]]; then
  printf '%s\n' "$GHOSTTY_TAG" > "$TAG_STAMP"
else
  # No-op when a stamp already exists and agrees: re-fetching one artifact from
  # the same pin leaves that stamp true, so there is nothing to correct.
  warn_unstamped_artifacts
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
