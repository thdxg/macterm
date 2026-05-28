#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$PWD"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData"

# Ensure GhosttyKit + bundled resources (themes, shell-integration) are present
# before xcodegen resolves the folder references. Idempotent and fast when they
# already exist.
"$PROJECT_ROOT/scripts/setup.sh"

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
