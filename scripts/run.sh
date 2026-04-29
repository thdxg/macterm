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
  build \
  | (xcbeautify --quiet 2>/dev/null || cat)

APP="$DERIVED_DATA/Build/Products/Debug/Macterm.app"
open "$APP"
