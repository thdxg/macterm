#!/usr/bin/env bash
set -euo pipefail

# Extra arguments go to xcodebuild, for example -only-testing:MactermTests/DocsLinkTests.
PROJECT_ROOT="$PWD"

# Xcode passes only TEST_RUNNER_ variables to the test host. WebsiteDocs reads
# MACTERM_WEBSITE_DIR, so pass it on.
if [[ -n "${MACTERM_WEBSITE_DIR:-}" ]]; then
  export TEST_RUNNER_MACTERM_WEBSITE_DIR="$MACTERM_WEBSITE_DIR"
fi
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
  -destination 'platform=macOS,arch=arm64' \
  test "$@" \
  | (xcbeautify --quiet 2>/dev/null || cat)
