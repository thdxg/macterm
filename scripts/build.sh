#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$PWD"
BUILD_DIR="$PROJECT_ROOT/build"
ARCH="${ARCH:-arm64}"
VERSION="${VERSION:-0.0.0}"
TRIPLE="${ARCH}-apple-macosx26.0"
BUILD_NUMBER=$(git -C "$PROJECT_ROOT" rev-list --count HEAD)
APP_BUNDLE="$BUILD_DIR/Macterm.app"
DMG_NAME="Macterm-${VERSION}-${ARCH}.dmg"

rm -rf "$APP_BUNDLE"

# Build release binary.
swift build -c release --triple "$TRIPLE"
SPM_BUILD_DIR=$(swift build -c release --triple "$TRIPLE" --show-bin-path)

# Assemble .app bundle.
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$SPM_BUILD_DIR/Macterm" "$APP_BUNDLE/Contents/MacOS/Macterm"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP_BUNDLE/Contents/MacOS/Macterm"

if [[ -d "$SPM_BUILD_DIR/Macterm_Macterm.bundle" ]]; then
  cp -R "$SPM_BUILD_DIR/Macterm_Macterm.bundle" "$APP_BUNDLE/Contents/Resources/Macterm_Macterm.bundle"
fi

cp "$PROJECT_ROOT/Macterm/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_BUNDLE/Contents/Info.plist"

# Substitute the Sparkle EdDSA public key if CI provided it. Local dev builds
# keep the placeholder — Sparkle refuses to install updates without a valid
# public key, so that's a safe default.
if [[ -n "${SPARKLE_ED_PUBLIC_KEY:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_ED_PUBLIC_KEY" "$APP_BUNDLE/Contents/Info.plist"
fi

# Bundle Sparkle.framework. SPM emits the right arch-slice next to the binary.
SPARKLE_FRAMEWORK="$SPM_BUILD_DIR/Sparkle.framework"
if [[ -d "$SPARKLE_FRAMEWORK" ]]; then
  mkdir -p "$APP_BUNDLE/Contents/Frameworks"
  cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi

# Generate the .icns from the asset catalog PNGs.
ICON_SOURCE="$PROJECT_ROOT/Macterm/Resources/Assets.xcassets/AppIcon.appiconset"
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
iconutil -c icns "$ICONSET_DIR" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET_DIR")"

# Ad-hoc sign. Sparkle's internal XPC services must be signed individually
# (docs explicitly warn against `--deep`). Sign innermost components first,
# then the framework, then the app.
SPARKLE_VER_B="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
if [[ -d "$SPARKLE_VER_B" ]]; then
  for xpc in "$SPARKLE_VER_B/XPCServices/"*.xpc; do
    [[ -e "$xpc" ]] || continue
    codesign --force --sign - -o runtime "$xpc"
  done
  [[ -e "$SPARKLE_VER_B/Autoupdate" ]] && codesign --force --sign - -o runtime "$SPARKLE_VER_B/Autoupdate"
  [[ -e "$SPARKLE_VER_B/Updater.app" ]] && codesign --force --sign - -o runtime "$SPARKLE_VER_B/Updater.app"
  codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --sign - "$APP_BUNDLE"

# Package into DMG.
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$BUILD_DIR/$DMG_NAME"
hdiutil create -volname "Macterm" -srcfolder "$DMG_STAGING" -ov -format UDZO "$BUILD_DIR/$DMG_NAME"
rm -rf "$DMG_STAGING"

echo "Done: build/$DMG_NAME"
