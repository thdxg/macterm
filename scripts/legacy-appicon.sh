#!/bin/bash
# Re-render Contents/Resources/AppIcon.icns in the dark appearance.
#
# Macterm/AppIcon.icon is an Icon Composer source, and actool compiles it into
# two things: an Assets.car holding the LAYER STACK (macOS 26 composites the
# appearance at runtime, so the Dock icon follows the system theme) and a flat
# AppIcon.icns for macOS 14/15, which predate appearance-aware app icons.
#
# actool renders that .icns from the resolved LIGHT appearance, and there is no
# icon.json key or actool flag to say otherwise — measured across three fill
# arrangements:
#
#   base system-light + dark override        -> light .icns
#   base dark solid   + light: system-light  -> light .icns
#   base dark solid   + no light entry       -> dark .icns
#
# So a single .icon cannot give both a theme-following icon on macOS 26 and a
# dark one on 14/15: making the .icns dark means making the LIGHT appearance
# dark, which pins every Tahoe user to the dark icon in light mode.
#
# Hence this script. It compiles a throwaway copy of the same .icon with the
# fill specializations collapsed to the dark solid, and swaps the resulting
# .icns over the one in the bundle. macOS 26 is unaffected: it resolves the
# icon through CFBundleIconName -> Assets.car and never reads this file.
#
# Rendering through actool rather than checking in a dark .icns is what keeps
# the two from drifting — the artwork, geometry, shadow and macOS icon-grid
# margin all come from the same source the real icon does, so editing
# AppIcon.icon is still a one-place change.
set -euo pipefail

ICON_SOURCE="${1:?usage: legacy-appicon.sh <AppIcon.icon> <app bundle>}"
APP_BUNDLE="${2:?usage: legacy-appicon.sh <AppIcon.icon> <app bundle>}"

TARGET="$APP_BUNDLE/Contents/Resources/AppIcon.icns"
if [[ ! -f "$TARGET" ]]; then
  echo "legacy-appicon: $TARGET is missing — actool did not emit a legacy icon" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The name actool renders under has to match the .icon's filename, and it names
# the output too — copying to AppIcon.icon yields AppIcon.icns.
cp -R "$ICON_SOURCE" "$WORK/AppIcon.icon"

# Collapse to a single unqualified fill. With no light entry to resolve, the
# light appearance inherits the dark solid and the .icns renders dark. The
# colour is read from the source's own dark specialization rather than restated
# here, so a recoloured icon cannot leave this script behind.
python3 - "$WORK/AppIcon.icon/icon.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as handle:
    icon = json.load(handle)

dark = next(
    (spec["value"] for spec in icon.get("fill-specializations", [])
     if spec.get("appearance") == "dark"),
    None,
)
if dark is None:
    sys.exit("legacy-appicon: icon.json has no dark fill specialization to render from")

icon["fill-specializations"] = [{"value": dark}]

with open(path, "w") as handle:
    json.dump(icon, handle, indent=2)
PY

# actool writes into --compile but will not create it.
mkdir -p "$WORK/out"

xcrun actool "$WORK/AppIcon.icon" \
  --compile "$WORK/out" \
  --platform macosx \
  --minimum-deployment-target "${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
  --app-icon AppIcon \
  --output-partial-info-plist "$WORK/partial.plist" \
  --errors \
  --warnings >/dev/null

if [[ ! -f "$WORK/out/AppIcon.icns" ]]; then
  echo "legacy-appicon: actool produced no AppIcon.icns for the dark appearance" >&2
  exit 1
fi

cp "$WORK/out/AppIcon.icns" "$TARGET"
