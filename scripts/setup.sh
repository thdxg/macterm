#!/usr/bin/env bash
set -euo pipefail

FORK_REPO="thdxg/ghostty"
XCFRAMEWORK_DIR="GhosttyKit.xcframework"
# Marker for the downloaded upstream resources (themes + shell-integration).
# Both dirs come entirely from the tarball — nothing is committed — so the
# presence of either signals the download already ran.
RESOURCES_MARKER="Macterm/Resources/shell-integration"

need_xcframework=true
need_resources=true
[[ -d "$XCFRAMEWORK_DIR" ]] && need_xcframework=false
[[ -d "$RESOURCES_MARKER" ]] && need_resources=false

if ! $need_xcframework && ! $need_resources; then
  echo "GhosttyKit and resources already present"
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
  # Bundled themes + shell-integration so named themes (Rose Pine, etc.) and
  # shell integration resolve without a separate Ghostty.app install. The
  # tarball contains top-level themes/ and shell-integration/ dirs; extract
  # them into Macterm/Resources/ (both are gitignored — Macterm ships the
  # upstream ghostty themes verbatim, none are committed).
  gh release download "$LATEST_TAG" --pattern "ghostty-resources.tar.gz" --repo "$FORK_REPO"
  mkdir -p Macterm/Resources
  tar xzf ghostty-resources.tar.gz -C Macterm/Resources
  rm ghostty-resources.tar.gz
fi
