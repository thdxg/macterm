#!/usr/bin/env bash
# Sign each DMG with Sparkle's sign_update, then append a new <item> per DMG
# to appcast.xml on the gh-pages branch.
#
# Required env:
#   SPARKLE_ED_PRIVATE_KEY — EdDSA private key (Sparkle format)
#   VERSION                — e.g. 1.8.0
#   TAG                    — e.g. v1.8.0
#   GH_TOKEN               — token with contents:write on this repo
#   GITHUB_REPOSITORY      — provided by GitHub Actions (owner/repo)
#
# Usage: publish-appcast.sh <dmg_dir>

set -euo pipefail

DMG_DIR="${1:-dmgs}"
PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
REPO_URL="https://github.com/${GITHUB_REPOSITORY}"

# Write the per-DMG <item> blocks into a temp file.
ITEMS_FILE=$(mktemp)
trap 'rm -f "$ITEMS_FILE"' EXIT

for dmg in "$DMG_DIR"/*.dmg; do
  name=$(basename "$dmg")
  url="${REPO_URL}/releases/download/${TAG}/${name}"
  sig=$(sign_update -f <(echo "$SPARKLE_ED_PRIVATE_KEY") "$dmg")
  cat >> "$ITEMS_FILE" <<ITEM
    <item>
      <title>Macterm ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <link>${REPO_URL}/releases/tag/${TAG}</link>
      <enclosure url="${url}" type="application/octet-stream" ${sig} />
    </item>
ITEM
done

# Clone (or initialize) gh-pages.
git config --global user.name "github-actions[bot]"
git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"

WORKDIR=$(mktemp -d)
CLONE_URL="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
if ! git clone --depth=1 --branch gh-pages "$CLONE_URL" "$WORKDIR" 2>/dev/null; then
  git clone "$CLONE_URL" "$WORKDIR"
  git -C "$WORKDIR" checkout --orphan gh-pages
  git -C "$WORKDIR" rm -rf . >/dev/null 2>&1 || true
fi

cd "$WORKDIR"

# Seed the appcast header on first publication.
if [[ ! -f appcast.xml ]]; then
  cat > appcast.xml <<'HEADER'
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Macterm</title>
    <link>https://thdxg.github.io/macterm/appcast.xml</link>
    <description>Updates for Macterm.</description>
    <language>en</language>
  </channel>
</rss>
HEADER
fi

# Insert the new <item>s before </channel>.
awk -v items_file="$ITEMS_FILE" '
  /<\/channel>/ {
    while ((getline line < items_file) > 0) print line
    close(items_file)
  }
  { print }
' appcast.xml > appcast.xml.new
mv appcast.xml.new appcast.xml

git add appcast.xml
git commit -m "Publish appcast for ${TAG}"
git push origin gh-pages

echo "Published appcast for ${TAG}"
