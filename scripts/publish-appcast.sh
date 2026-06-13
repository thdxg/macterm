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
PAGES_URL="https://thdxg.github.io/macterm"
NOTES_REL_PATH="notes/${TAG}.html"
NOTES_URL="${PAGES_URL}/${NOTES_REL_PATH}"

# Fetch the GitHub Release body (Markdown) and render to HTML via the GitHub
# API's Markdown endpoint. Sparkle's update dialog loads this URL into a
# WebView, so we wrap the rendered body in a tiny standalone document with
# system-matching typography. Empty release notes are tolerated — we still
# write a placeholder so the link resolves.
NOTES_BODY_FILE=$(mktemp)
NOTES_HTML_FILE=$(mktemp)
ITEMS_FILE=""
trap 'rm -f "$NOTES_BODY_FILE" "$NOTES_HTML_FILE" ${ITEMS_FILE:+"$ITEMS_FILE"}' EXIT

gh release view "$TAG" --json body --jq .body > "$NOTES_BODY_FILE"
if [[ ! -s "$NOTES_BODY_FILE" ]]; then
  echo "_No release notes provided._" > "$NOTES_BODY_FILE"
fi

# Render Markdown → HTML using GitHub's renderer (same one that produces the
# release page). Wrap in a minimal document so Sparkle's WebView gets readable
# typography without inheriting any GitHub chrome.
RENDERED_HTML=$(gh api -X POST /markdown -f mode=gfm -F "text=@${NOTES_BODY_FILE}")
cat > "$NOTES_HTML_FILE" <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Macterm ${VERSION} release notes</title>
  <style>
    body { font: 13px -apple-system, system-ui, sans-serif; color: #1d1d1f; padding: 16px; margin: 0; }
    @media (prefers-color-scheme: dark) { body { color: #f5f5f7; background: transparent; } a { color: #6cb4ff; } }
    h1, h2, h3 { margin-top: 0.6em; margin-bottom: 0.3em; }
    h1 { font-size: 1.3em; } h2 { font-size: 1.15em; } h3 { font-size: 1em; }
    p, ul, ol { margin: 0.4em 0; }
    ul, ol { padding-left: 1.4em; }
    code { background: rgba(127, 127, 127, 0.15); padding: 0 4px; border-radius: 3px; font: 12px ui-monospace, monospace; }
    pre { background: rgba(127, 127, 127, 0.12); padding: 8px; border-radius: 4px; overflow-x: auto; }
    pre code { background: transparent; padding: 0; }
    a { color: #0366d6; text-decoration: none; }
    a:hover { text-decoration: underline; }
  </style>
</head>
<body>
${RENDERED_HTML}
</body>
</html>
HTML

# Write the per-DMG <item> blocks into a temp file.
ITEMS_FILE=$(mktemp)

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
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${NOTES_URL}</sparkle:releaseNotesLink>
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

mkdir -p notes
cp "$NOTES_HTML_FILE" "$NOTES_REL_PATH"

git add appcast.xml "$NOTES_REL_PATH"
git commit -m "Publish appcast for ${TAG}"
git push origin gh-pages

echo "Published appcast for ${TAG}"
