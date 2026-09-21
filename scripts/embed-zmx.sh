#!/usr/bin/env bash
# Embed the built zmx binary into the app bundle at Contents/Resources/zmx/zmx.
#
# Runs as a project.yml post-compile build phase. ZmxClient resolves the binary
# via Bundle.main.url(forResource:"zmx", withExtension:nil, subdirectory:"zmx"),
# matching this `zmx/zmx` layout. Kept in its own `zmx/` subdir (not loose in
# Resources/) so the lookup is unambiguous and mirrors Supacode's bundle layout.
set -euo pipefail

# Prefer Xcode's SRCROOT (build-phase env); fall back to the repo root so the
# script is runnable standalone.
srcroot="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# The prebuilt binary downloaded by setup.sh from the thdxg/zmx release.
zmx_source="${srcroot}/Macterm/Resources/zmx/zmx"

if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
  echo "error: embed-zmx.sh must run inside an Xcode build phase (missing TARGET_BUILD_DIR)" >&2
  exit 1
fi

if [[ ! -x "${zmx_source}" ]]; then
  echo "error: ${zmx_source} not found. Run 'mise run setup' to download it." >&2
  exit 1
fi

destination_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/zmx"
mkdir -p "${destination_dir}"
# -c clones (copy-on-write) when possible; -p preserves the executable bit.
cp -cp "${zmx_source}" "${destination_dir}/zmx" 2>/dev/null || cp -p "${zmx_source}" "${destination_dir}/zmx"
chmod +x "${destination_dir}/zmx"

# Sign the copy with the same identity Xcode signs the app with (ad-hoc in a
# local build, the stable release certificate in CI). The release download is
# only linker-signed, and Xcode never re-signs a Mach-O it merely copies into
# Resources/. That signature is load-bearing: each zmx session daemon disclaims
# the app at spawn and becomes the *responsible process* for every program in
# its session (see the fork's daemonize.zig and AGENTS.md), so macOS records
# Local Network and TCC grants for pane programs against zmx's own identity —
# the CFBundleIdentifier in its embedded Info.plist plus this signature. An
# ad-hoc signature is a fresh identity per build, which would turn every
# update into a new prompt and a lost grant. codesign takes the signing
# identifier from the embedded Info.plist, so none is passed here.
signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
codesign --force --sign "${signing_identity}" --timestamp=none "${destination_dir}/zmx"
echo "✓ embedded zmx → ${destination_dir}/zmx (signed: ${signing_identity})"
