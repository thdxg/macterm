#!/usr/bin/env bash
# Embed the built zmx binary into the app bundle at Contents/Resources/zmx/zmx,
# and the gzip server builds for every host target at Contents/Resources/server.
#
# Runs as a project.yml post-compile build phase. ZmxClient resolves the binary
# via Bundle.main.url(forResource:"zmx", withExtension:nil, subdirectory:"zmx"),
# matching this `zmx/zmx` layout. Kept in its own `zmx/` subdir (not loose in
# Resources/) so the lookup is unambiguous and mirrors Supacode's bundle layout.
set -euo pipefail

# Prefer Xcode's SRCROOT (build-phase env); fall back to the repo root so the
# script is runnable standalone.
srcroot="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# The server that setup.sh built from server/ or downloaded as its prebuilt.
zmx_source="${srcroot}/Macterm/Resources/zmx/zmx"

if [[ -z "${TARGET_BUILD_DIR:-}" || -z "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
  echo "error: embed-zmx.sh must run in an Xcode build phase (TARGET_BUILD_DIR is not set)" >&2
  exit 1
fi

if [[ ! -x "${zmx_source}" ]]; then
  echo "error: ${zmx_source} is not there. Run 'mise run setup' to get it." >&2
  exit 1
fi

destination_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/zmx"
mkdir -p "${destination_dir}"
# -c clones (copy-on-write) when possible; -p preserves the executable bit.
cp -cp "${zmx_source}" "${destination_dir}/zmx" 2>/dev/null || cp -p "${zmx_source}" "${destination_dir}/zmx"
chmod +x "${destination_dir}/zmx"

# Sign the copy as the APP: the same certificate Xcode signs the bundle with
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
codesign --force --sign "${signing_identity}" --identifier "${PRODUCT_BUNDLE_IDENTIFIER}" \
  --timestamp=none "${destination_dir}/zmx"
echo "✓ embedded zmx → ${destination_dir}/zmx (signed as ${PRODUCT_BUNDLE_IDENTIFIER}: ${signing_identity})"

# The server builds for an install on a host (design/007 §3A), one gzip file
# for each target, named for the build key: macOS universal from the signed
# copy above, the Linux builds as setup.sh made them. The app's own signature
# seals them, as every file in Contents/Resources.
release_file="${srcroot}/Macterm/Resources/zmx-release.json"
key="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag"])' "${release_file}")"
server_dir="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/server"
rm -rf "${server_dir}"
mkdir -p "${server_dir}"
gzip -n -9 -c "${destination_dir}/zmx" > "${server_dir}/macterm-${key}-universal-macos.gz"
for target in x86_64-linux aarch64-linux; do
  linux_build="${srcroot}/Macterm/Resources/zmx/macterm-${key}-${target}.gz"
  if [[ ! -f "${linux_build}" ]]; then
    echo "error: ${linux_build} is not there. Run 'mise run setup' to get it." >&2
    exit 1
  fi
  cp -p "${linux_build}" "${server_dir}/"
done
echo "✓ embedded the server builds ${key} → ${server_dir}"
