#!/usr/bin/env bash
set -euo pipefail

# Auto-fix formatting issues in place. Pass --check (or -c) to verify
# formatting without writing changes — used by CI.
if [[ ${1:-} == "--check" || ${1:-} == "-c" ]]; then
  swiftformat --lint .
else
  swiftformat .
fi
