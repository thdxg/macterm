#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$PWD"
BUILD_DIR="$PROJECT_ROOT/build"
VERSION="${VERSION:-0.0.0}"

# shellcheck source=scripts/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Sparkle compares CFBundleVersion against the appcast's sparkle:version when
# deciding whether an update is newer, so the two must agree exactly — both go
# through `sparkle_comparison_version` (see _lib.sh for why a raw `-beta.N`
# string can't be used, and why a commit count can't either: it can stay equal
# across two tags built from the same commit and trip "You're up to date").
# CFBundleShortVersionString keeps the human-readable $VERSION for display.
BUILD_NUMBER="$(sparkle_comparison_version "$VERSION")"
GIT_COMMIT=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
# Baked into Info.plist as MactermUpdateChannel and used as the DEFAULT update
# channel when the user has never picked one (Preferences.init). A tip DMG
# installed by hand would otherwise sit on the stable channel and, because a tip
# version outranks every stable release of the same base, see "You're up to
# date" forever. See macterm_update_channel in _lib.sh for why beta needs no
# such treatment.
MACTERM_UPDATE_CHANNEL="$(macterm_update_channel "$VERSION")"
SPARKLE_ED_PUBLIC_KEY="${SPARKLE_ED_PUBLIC_KEY:-SPARKLE_ED_PUBLIC_KEY_PLACEHOLDER}"

# Optional stable code-signing identity (a SHA-1 identity hash or a certificate
# name resolvable in the keychain). macOS TCC keys privacy grants (Documents,
# Downloads, …) to the app's code-signing designated requirement; an ad-hoc
# signature's requirement is the per-build CDHash, so every update looks like a
# brand-new app to TCC and drops every grant. Release CI sets this to the
# imported self-signed release certificate (see release.yml's "Import signing
# certificate" step) so the requirement stays stable across releases and grants
# survive updates. Unset = ad-hoc (project.yml's default), which is fine for
# local and benchmark builds that are never distributed.
CODESIGN_IDENTITY="${MACTERM_CODESIGN_IDENTITY:-}"
SIGNING_OVERRIDES=()
if [[ -n "$CODESIGN_IDENTITY" ]]; then
  SIGNING_OVERRIDES+=(CODE_SIGN_IDENTITY="$CODESIGN_IDENTITY")
fi
DMG_NAME="Macterm-${VERSION}.dmg"
DERIVED_DATA="$BUILD_DIR/DerivedData"
ARCHIVE_PATH="$BUILD_DIR/Macterm.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"

# Ensure GhosttyKit + bundled resources (themes, shell-integration) are present
# before xcodegen resolves the folder references. Idempotent; no-op in CI where
# ci:setup already ran.
"$PROJECT_ROOT/scripts/setup.sh"

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
  MACTERM_UPDATE_CHANNEL="$MACTERM_UPDATE_CHANNEL" \
  SPARKLE_ED_PUBLIC_KEY="$SPARKLE_ED_PUBLIC_KEY" \
  ${SIGNING_OVERRIDES[@]+"${SIGNING_OVERRIDES[@]}"} \
  archive \
  | (xcbeautify --quiet 2>/dev/null || cat)

# Copy the .app straight out of the archive. There's nothing to re-sign or
# notarize — the archive's Products/Applications already holds the fully-built,
# signed bundle (Sparkle and its XPC services included), signed either ad-hoc
# (local) or with the stable release certificate (CI, via SIGNING_OVERRIDES).
# `ditto` (not cp) preserves the framework symlinks a valid macOS bundle needs.
#
# This deliberately avoids `xcodebuild -exportArchive`: its `-exportOptionsPlist`
# `method` value is unstable across Xcode releases (Apple renamed the macOS
# export methods in Xcode 16, breaking the old `mac-application` value — the
# failure that motivated this). A direct copy has no version-sensitive tokens.
ARCHIVED_APP="$ARCHIVE_PATH/Products/Applications/Macterm.app"
if [[ ! -d "$ARCHIVED_APP" ]]; then
  echo "ERROR: $ARCHIVED_APP not found in archive" >&2
  exit 1
fi
mkdir -p "$EXPORT_PATH"
ditto "$ARCHIVED_APP" "$EXPORT_PATH/Macterm.app"

APP_BUNDLE="$EXPORT_PATH/Macterm.app"
# Sanity-check the copy is a valid, signed bundle before building a DMG from it.
if ! codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null; then
  echo "ERROR: exported $APP_BUNDLE failed code-signature verification" >&2
  exit 1
fi
# When a stable identity was requested, an ad-hoc signature slipping through
# would ship an update that silently resets every user's TCC grants — exactly
# what the identity exists to prevent — so fail rather than package it.
if [[ -n "$CODESIGN_IDENTITY" ]] \
  && codesign --display --verbose "$APP_BUNDLE" 2>&1 | grep -q "Signature=adhoc"; then
  echo "ERROR: $APP_BUNDLE is ad-hoc signed despite MACTERM_CODESIGN_IDENTITY being set" >&2
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
