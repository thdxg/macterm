#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

run_step "Checking formatting..." swiftformat --lint .

if command -v swiftlint &>/dev/null; then
  run_step "Linting..." swiftlint lint --strict --quiet
fi
