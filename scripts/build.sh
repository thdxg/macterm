#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/_lib.sh"

PROJECT_ROOT="$PWD"
BUILD_DIR="$PROJECT_ROOT/build"
ARCH="${ARCH:-arm64}"
VERSION="${VERSION:-0.0.0}"
TRIPLE="${ARCH}-apple-macosx26.0"
BUILD_NUMBER=$(git -C "$PROJECT_ROOT" rev-list --count HEAD)
APP_BUNDLE="$BUILD_DIR/Macterm.app"
DMG_NAME="Macterm-${VERSION}-${ARCH}.dmg"

rm -rf "$APP_BUNDLE"

run_step "Building release ($ARCH)..." swift build -c release --triple "$TRIPLE"

SPM_BUILD_DIR=$(swift build -c release --triple "$TRIPLE" --show-bin-path)

run_step "Assembling app bundle..." bash -c '
  mkdir -p "'"$APP_BUNDLE"'/Contents/MacOS" "'"$APP_BUNDLE"'/Contents/Resources"
  cp "'"$SPM_BUILD_DIR"'/Macterm" "'"$APP_BUNDLE"'/Contents/MacOS/Macterm"
  install_name_tool -add_rpath @executable_path/../Frameworks "'"$APP_BUNDLE"'/Contents/MacOS/Macterm"

  if [[ -d "'"$SPM_BUILD_DIR"'/Macterm_Macterm.bundle" ]]; then
    cp -R "'"$SPM_BUILD_DIR"'/Macterm_Macterm.bundle" "'"$APP_BUNDLE"'/Contents/Resources/Macterm_Macterm.bundle"
  fi

  cp "'"$PROJECT_ROOT"'/Macterm/Info.plist" "'"$APP_BUNDLE"'/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString '"$VERSION"'" "'"$APP_BUNDLE"'/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion '"$BUILD_NUMBER"'" "'"$APP_BUNDLE"'/Contents/Info.plist"

  ICON_SOURCE="'"$PROJECT_ROOT"'/Macterm/Resources/Assets.xcassets/AppIcon.appiconset"
  ICONSET_DIR=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET_DIR"
  cp "$ICON_SOURCE/icon_16.png" "$ICONSET_DIR/icon_16x16.png"
  cp "$ICON_SOURCE/icon_16@2x.png" "$ICONSET_DIR/icon_16x16@2x.png"
  cp "$ICON_SOURCE/icon_32.png" "$ICONSET_DIR/icon_32x32.png"
  cp "$ICON_SOURCE/icon_32@2x.png" "$ICONSET_DIR/icon_32x32@2x.png"
  cp "$ICON_SOURCE/icon_128.png" "$ICONSET_DIR/icon_128x128.png"
  cp "$ICON_SOURCE/icon_128@2x.png" "$ICONSET_DIR/icon_128x128@2x.png"
  cp "$ICON_SOURCE/icon_256.png" "$ICONSET_DIR/icon_256x256.png"
  cp "$ICON_SOURCE/icon_256@2x.png" "$ICONSET_DIR/icon_256x256@2x.png"
  cp "$ICON_SOURCE/icon_512.png" "$ICONSET_DIR/icon_512x512.png"
  cp "$ICON_SOURCE/icon_512@2x.png" "$ICONSET_DIR/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET_DIR" -o "'"$APP_BUNDLE"'/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET_DIR")"
'

run_step "Signing app bundle..." codesign --force --sign - "$APP_BUNDLE"

run_step "Creating DMG..." bash -c '
  DMG_STAGING="'"$BUILD_DIR"'/dmg-staging"
  rm -rf "$DMG_STAGING"
  mkdir -p "$DMG_STAGING"
  cp -R "'"$APP_BUNDLE"'" "$DMG_STAGING/"
  ln -s /Applications "$DMG_STAGING/Applications"
  rm -f "'"$BUILD_DIR"'/'"$DMG_NAME"'"
  hdiutil create -volname "Macterm" -srcfolder "$DMG_STAGING" -ov -format UDZO "'"$BUILD_DIR"'/'"$DMG_NAME"'"
  rm -rf "$DMG_STAGING"
'

step "Done: build/$DMG_NAME"
