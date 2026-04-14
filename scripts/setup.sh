#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

FORK_REPO="thdxg/ghostty"
XCFRAMEWORK_DIR="GhosttyKit.xcframework"

if [[ -d "$XCFRAMEWORK_DIR" ]]; then
  step "GhosttyKit already present"
  exit 0
fi

run_step "Fetching latest GhosttyKit release..." bash -c '
  LATEST_TAG=$(gh release list --repo "'"$FORK_REPO"'" --limit 1 --json tagName -q ".[0].tagName")
  [[ -z "$LATEST_TAG" ]] && echo "Error: No releases found" && exit 1
  gh release download "$LATEST_TAG" --pattern "GhosttyKit.xcframework.tar.gz" --repo "'"$FORK_REPO"'"
'

run_step "Extracting xcframework..." bash -c '
  tar xzf GhosttyKit.xcframework.tar.gz
  rm GhosttyKit.xcframework.tar.gz
'
