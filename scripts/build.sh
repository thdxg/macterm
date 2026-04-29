#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$PWD"
BUILD_DIR="$PROJECT_ROOT/build"
VERSION="${VERSION:-0.0.0}"
# Sparkle compares CFBundleVersion against the appcast's sparkle:version when
# deciding whether an update is newer. Use the marketing string for both so a
# new tag always wins — a raw commit count can stay equal across two
# consecutive tags built from the same commit and trip "You're up to date".
BUILD_NUMBER="$VERSION"
GIT_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
SPARKLE_ED_PUBLIC_KEY="${SPARKLE_ED_PUBLIC_KEY:-SPARKLE_ED_PUBLIC_KEY_PLACEHOLDER}"
DMG_NAME="Macterm-${VERSION}.dmg"
DERIVED_DATA="$BUILD_DIR/DerivedData"
ARCHIVE_PATH="$BUILD_DIR/Macterm.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

# Regenerate the Xcode project so any project.yml edits land in CI builds
# without requiring a developer to commit the generated .xcodeproj.
xcodegen generate --spec "$PROJECT_ROOT/project.yml" >/dev/null

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

# Archive: Xcode handles universal binary arch ($(ARCHS_STANDARD) is
# arm64+x86_64 in Release), embeds Sparkle.framework, signs everything
# (including Sparkle's XPC services) with the configured identity, and
# substitutes our Info.plist build-setting tokens.
xcodebuild \
  -project Macterm.xcodeproj \
  -scheme Macterm \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE_PATH" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  GIT_COMMIT="$GIT_COMMIT" \
  SPARKLE_ED_PUBLIC_KEY="$SPARKLE_ED_PUBLIC_KEY" \
  archive \
  | (xcbeautify --quiet 2>/dev/null || cat)

# Export the .app from the archive. Use a minimal export plist that produces
# a copy of the .app without re-signing or notarizing — we ship ad-hoc.
EXPORT_PLIST=$(mktemp)
cat > "$EXPORT_PLIST" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>mac-application</string>
    <key>signingStyle</key>
    <string>manual</string>
</dict>
</plist>
EOF

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  | (xcbeautify --quiet 2>/dev/null || cat)
rm -f "$EXPORT_PLIST"

APP_BUNDLE="$EXPORT_PATH/Macterm.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "ERROR: $APP_BUNDLE not produced by xcodebuild -exportArchive" >&2
  exit 1
fi

# Package into a compressed DMG with an Applications symlink for drag-install.
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$BUILD_DIR/$DMG_NAME"
hdiutil create -volname "Macterm" -srcfolder "$DMG_STAGING" -ov -format UDZO "$BUILD_DIR/$DMG_NAME"
rm -rf "$DMG_STAGING"

echo "Done: build/$DMG_NAME"
