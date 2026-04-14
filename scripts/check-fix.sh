#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

run_step "Formatting..." swiftformat .

if command -v swiftlint &>/dev/null; then
  run_step "Auto-fixing lint issues..." bash -c 'swiftlint lint --fix --quiet || true'
  run_step "Linting..." swiftlint lint --strict --quiet
fi
