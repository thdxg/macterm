#!/usr/bin/env bash
# Embed the zmx binaries into the app bundle at Contents/Resources/zmx/.
#
# Runs as a project.yml post-compile build phase. ZmxClient resolves each binary
# via Bundle.main.url(forResource:<name>, withExtension:nil, subdirectory:"zmx"),
# matching this `zmx/<name>` layout. Kept in its own `zmx/` subdir (not loose in
# Resources/) so the lookup is unambiguous and mirrors Supacode's bundle layout.
#
# Two binaries, one for each zmx wire protocol (ZmxProtocol): `zmx`, the v1
# binary that starts every new session, and `zmx-legacy`, which reaches only
# the sessions that a Macterm from before zmx 1.0 started.
set -euo pipefail

# Prefer Xcode's SRCROOT (build-phase env); fall back to the repo root so the
# script is runnable standalone.
srcroot="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# The prebuilt binaries downloaded by setup.sh from the thdxg/zmx releases.
source_dir="${srcroot}/Macterm/Resources/zmx"

if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
  echo "error: embed-zmx.sh must run in an Xcode build phase (TARGET_BUILD_DIR is not set)" >&2
  exit 1
fi

destination_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/zmx"
mkdir -p "${destination_dir}"

# Sign each copy as the APP: the same certificate Xcode signs the bundle with
# (ad-hoc in a local build, the identity that Configs/Local.xcconfig names in a
# Debug build that has one, the stable release certificate in CI) and, more
# importantly, the app's own bundle identifier. Each zmx session daemon
# disclaims the app at spawn and becomes the *responsible process* for every
# program in its session (see the fork's daemonize.zig and AGENTS.md), and
# macOS identifies a responsible process by its code signature's identifier:
# with Macterm's, the daemon resolves to Macterm's name, usage descriptions
# and existing Local Network / TCC grants, so pane programs are covered by the
# one grant the user already made. Anything else — the release download's
# linker-signed identity, or a separate one — names a second thing ("zmx") in
# the prompt and needs a second grant. Xcode never re-signs a Mach-O it merely
# copies into Resources/, hence doing it here.
signing_identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"

for name in zmx zmx-legacy; do
  source="${source_dir}/${name}"
  if [[ ! -x "${source}" ]]; then
    echo "error: ${source} is not there. Run 'mise run setup' to download it." >&2
    exit 1
  fi
  # -c clones (copy-on-write) when possible; -p preserves the executable bit.
  cp -cp "${source}" "${destination_dir}/${name}" 2>/dev/null || cp -p "${source}" "${destination_dir}/${name}"
  chmod +x "${destination_dir}/${name}"
  codesign --force --sign "${signing_identity}" --identifier "${PRODUCT_BUNDLE_IDENTIFIER}" \
    --timestamp=none "${destination_dir}/${name}"
  echo "✓ embedded ${name} → ${destination_dir}/${name} (signed as ${PRODUCT_BUNDLE_IDENTIFIER}: ${signing_identity})"
done
