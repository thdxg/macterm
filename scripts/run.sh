#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

run_step "Building..." swift build

step "Launching Macterm"
swift run Macterm
