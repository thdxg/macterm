#!/usr/bin/env bash
set -euo pipefail

FORK_REPO="thdxg/ghostty"
XCFRAMEWORK_DIR="GhosttyKit.xcframework"

if [[ -d "$XCFRAMEWORK_DIR" ]]; then
  echo "GhosttyKit already present"
  exit 0
fi

LATEST_TAG=$(gh release list --repo "$FORK_REPO" --limit 1 --json tagName -q ".[0].tagName")
if [[ -z "$LATEST_TAG" ]]; then
  echo "Error: No releases found" >&2
  exit 1
fi

gh release download "$LATEST_TAG" --pattern "GhosttyKit.xcframework.tar.gz" --repo "$FORK_REPO"

tar xzf GhosttyKit.xcframework.tar.gz
rm GhosttyKit.xcframework.tar.gz
