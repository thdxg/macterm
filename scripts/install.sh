#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

run_step "Copying to /Applications..." bash -c '
  rm -rf /Applications/Macterm.app
  ditto ./build/Macterm.app /Applications/Macterm.app
'

run_step "Verifying signature..." codesign --verify --deep --strict --verbose=2 /Applications/Macterm.app
