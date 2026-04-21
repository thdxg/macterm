#!/usr/bin/env bash
set -euo pipefail

# Check formatting without writing changes.
swiftformat --lint .
