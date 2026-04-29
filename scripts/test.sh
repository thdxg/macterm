#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$PWD"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData"

xcodegen generate --spec "$PROJECT_ROOT/project.yml" >/dev/null

xcodebuild \
  -project Macterm.xcodeproj \
  -scheme Macterm \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS,arch=arm64' \
  test \
  | (xcbeautify --quiet 2>/dev/null || cat)
