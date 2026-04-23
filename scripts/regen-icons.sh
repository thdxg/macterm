#!/usr/bin/env bash
set -euo pipefail

# Regenerates the bundled app icon PNGs (16/32/128/256/512 @1x+@2x) plus
# the 1024 AppIcon.png from assets/icon.png. Run this whenever you update
# the source icon.

SRC="assets/icon.png"
DST="Macterm/Resources/Assets.xcassets/AppIcon.appiconset"

if [[ ! -f "$SRC" ]]; then
  echo "missing $SRC" >&2
  exit 1
fi

magick "$SRC" -resize 1024x1024 Macterm/Resources/AppIcon.png

for entry in \
  16:icon_16.png \
  32:icon_16@2x.png \
  32:icon_32.png \
  64:icon_32@2x.png \
  128:icon_128.png \
  256:icon_128@2x.png \
  256:icon_256.png \
  512:icon_256@2x.png \
  512:icon_512.png \
  1024:icon_512@2x.png; do
  size="${entry%%:*}"
  name="${entry##*:}"
  magick "$SRC" -resize "${size}x${size}" "$DST/$name"
done

echo "regenerated icons from $SRC"
