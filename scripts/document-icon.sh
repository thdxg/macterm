#!/usr/bin/env bash
# Draw Macterm/Document.icns again from Macterm/AppIcon.icon.
#
# Finder shows this icon for a file that opens with Macterm by default
# (CFBundleTypeIconFile in Macterm/Info.plist). Run this script after a change
# to the app icon, and commit the new Document.icns.
#
# The glyph is real Liquid Glass: the Debug build's macterm-icon-renderer draws
# it from the app icon. The script therefore builds Debug first, and it needs
# macOS 26 or later on Apple silicon, as the adaptive icon does.
#
# Usage:
#   scripts/document-icon.sh              build Debug, then draw the icon
#   scripts/document-icon.sh --no-build   use the last Debug build
set -euo pipefail

PROJECT_ROOT="$PWD"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData"
APP="$DERIVED_DATA/Build/Products/Debug/Macterm Debug.app"

build=true
for arg in "$@"; do
  case "$arg" in
    --no-build) build=false ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if $build; then
  "$PROJECT_ROOT/scripts/setup.sh"
  xcodegen generate --spec "$PROJECT_ROOT/project.yml" >/dev/null
  xcodebuild \
    -project Macterm.xcodeproj \
    -scheme Macterm \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    build \
    | (xcbeautify --quiet 2>/dev/null || cat)
fi

HELPER="$APP/Contents/Helpers/macterm-icon-renderer"
if [[ ! -x "$HELPER" ]]; then
  echo "No Debug build at $APP. Run the script without --no-build." >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

swift "$PROJECT_ROOT/scripts/document-icon/render.swift" \
  "$PROJECT_ROOT/Macterm/AppIcon.icon" "$HELPER" "$WORK_DIR/Document.iconset"
iconutil -c icns -o "$PROJECT_ROOT/Macterm/Document.icns" "$WORK_DIR/Document.iconset"
echo "Wrote Macterm/Document.icns"
