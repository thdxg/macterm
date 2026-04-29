#!/usr/bin/env bash
set -euo pipefail

# Source app comes from `mise run build`, which exports a Release-signed .app
# under build/export/Macterm.app.
SRC="./build/export/Macterm.app"
if [[ ! -d "$SRC" ]]; then
  echo "ERROR: $SRC not found — run 'mise run build' first." >&2
  exit 1
fi

rm -rf /Applications/Macterm.app
ditto "$SRC" /Applications/Macterm.app

codesign --verify --deep --strict --verbose=2 /Applications/Macterm.app
