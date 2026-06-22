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
  # Prebuilt arm64 zmx binary from the thdxg/zmx release. Shipped as a tarball
  # (preserves the executable bit through the GitHub asset round-trip) holding a
  # single `zmx` binary; extracted to Macterm/Resources/zmx/zmx (gitignored).
  ZMX_TAG=$(gh release list --repo "$ZMX_REPO" --limit 1 --json tagName -q ".[0].tagName")
  if [[ -z "$ZMX_TAG" ]]; then
    echo "Error: No zmx releases found in $ZMX_REPO" >&2
    exit 1
  fi
  gh release download "$ZMX_TAG" --pattern "zmx-aarch64-macos.tar.gz" --repo "$ZMX_REPO"
  rm -rf Macterm/Resources/zmx
  mkdir -p Macterm/Resources/zmx
  tar xzf zmx-aarch64-macos.tar.gz -C Macterm/Resources/zmx
  chmod +x Macterm/Resources/zmx/zmx
  rm zmx-aarch64-macos.tar.gz
fi
