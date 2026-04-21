#!/usr/bin/env bash
set -euo pipefail

# Auto-fix formatting issues in place.
swiftformat .

if command -v swiftlint &>/dev/null; then
  swiftlint lint --fix --quiet || true
fi
