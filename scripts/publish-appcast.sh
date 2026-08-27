#!/usr/bin/env bash
# Sign each DMG with Sparkle's sign_update, then append a new <item> per DMG
# to appcast.xml on the gh-pages branch.
#
# Required env:
#   SPARKLE_ED_PRIVATE_KEY — EdDSA private key (Sparkle format)
#   VERSION                — e.g. 1.8.0, or 0.9.0-beta.1 for a prerelease
#   TAG                    — e.g. v1.8.0
#   GH_TOKEN               — token with contents:write on this repo
#   GITHUB_REPOSITORY      — provided by GitHub Actions (owner/repo)
#
# Optional env:
#   PRERELEASE             — "true" for a prerelease. Required for any channel.
#   CHANNEL                — Sparkle channel name for the new items. Empty =
#                            the default channel (visible to everyone).
#                            Defaults to "beta" when PRERELEASE is true, which
#                            is the historical behaviour; release-tip.yml passes
#                            "tip". Only updaters whose allowedChannels includes
#                            the name (Settings → Updates → Channel) see them.
#   ROLLING                — "true" to REPLACE the channel's items instead of
#                            appending: every existing item carrying $CHANNEL is
#                            removed before the new one is inserted, so a
#                            per-commit channel can't grow the feed without
#                            bound. Also refuses to go backwards (see below).
#
# ONE feed, N channels — deliberately not a file per channel. Sparkle filters
# channels client-side, so a tip follower, a beta tester and a stable user read
# the same URL and diverge only on the delegate's allowedChannels. That also
# means someone who opts back out immediately sees their old channel again, with
# no feed-URL migration. (This is where we diverge from ghostty, which serves
# tip.files/release.files appcasts picked by a `feedURLString` delegate because
# it did not want to share one file. Macterm already shipped the channel-element
# mechanism for beta and it works, so tip is one more channel rather than a
# second feed and a second Info.plist SUFeedURL story.)
#
# Usage: publish-appcast.sh <dmg_dir>

set -euo pipefail

# shellcheck source=scripts/_lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

DMG_DIR="${1:-dmgs}"
PRERELEASE="${PRERELEASE:-false}"
ROLLING="${ROLLING:-false}"
# An explicit CHANNEL wins; otherwise a prerelease means beta, preserving the
# behaviour from before tip existed (release.yml still passes only PRERELEASE).
CHANNEL="${CHANNEL:-}"
if [[ -z "$CHANNEL" && "$PRERELEASE" == "true" ]]; then
  CHANNEL="beta"
fi
# A channel-tagged item is invisible to default updaters, so tagging a STABLE
# release would silently cut off every user who hasn't opted into a channel.
# Refuse rather than publish an item nobody can see.
if [[ -n "$CHANNEL" && "$PRERELEASE" != "true" ]]; then
  echo "error: CHANNEL='$CHANNEL' requires PRERELEASE=true; a stable release must carry no channel" >&2
  exit 1
fi
if [[ "$ROLLING" == "true" && -z "$CHANNEL" ]]; then
  echo "error: ROLLING=true needs a CHANNEL to scope the replacement to" >&2
  exit 1
fi
# MUST match the app's CFBundleVersion, which build.sh derives with the same
# helper — Sparkle orders updates by this, not by the display string.
COMPARISON_VERSION="$(sparkle_comparison_version "$VERSION")"
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

# Collect DMGs into an array so an empty dir fails with a clear message rather
# than iterating the literal `dmgs/*.dmg` glob and handing `sign_update` a
# nonexistent path (an opaque error).
shopt -s nullglob
dmgs=("$DMG_DIR"/*.dmg)
shopt -u nullglob
if [[ ${#dmgs[@]} -eq 0 ]]; then
  echo "error: no .dmg files found in '$DMG_DIR'" >&2
  exit 1
fi

# Prereleases carry <sparkle:channel>NAME</sparkle:channel>; stable items carry
# no channel element at all (Sparkle's default channel, visible to everyone).
# The channel literals are a wire contract with `UpdateChannel` in
# Macterm/App/Preferences.swift — UpdaterChannelTests pins them on the Swift
# side by reading this script.
CHANNEL_LINE=""
TITLE_SUFFIX=""
if [[ -n "$CHANNEL" ]]; then
  CHANNEL_LINE=$'\n      <sparkle:channel>'"${CHANNEL}"'</sparkle:channel>'
  TITLE_SUFFIX=" (${CHANNEL})"
fi

for dmg in "${dmgs[@]}"; do
  name=$(basename "$dmg")
  url="${REPO_URL}/releases/download/${TAG}/${name}"
  sig=$(sign_update -f <(echo "$SPARKLE_ED_PRIVATE_KEY") "$dmg")
  cat >> "$ITEMS_FILE" <<ITEM
    <item>
      <title>Macterm ${VERSION}${TITLE_SUFFIX}</title>
      <pubDate>${PUB_DATE}</pubDate>${CHANNEL_LINE}
      <sparkle:version>${COMPARISON_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>${NOTES_URL}</sparkle:releaseNotesLink>
      <link>${REPO_URL}/releases/tag/${TAG}</link>
      <enclosure url="${url}" type="application/octet-stream" ${sig} />
    </item>
ITEM
done

# Clone (or initialize) gh-pages.
WORKDIR=$(mktemp -d)
CLONE_URL="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
if ! git clone --depth=1 --branch gh-pages "$CLONE_URL" "$WORKDIR" 2>/dev/null; then
  git clone "$CLONE_URL" "$WORKDIR"
  git -C "$WORKDIR" checkout --orphan gh-pages
  git -C "$WORKDIR" rm -rf . >/dev/null 2>&1 || true
fi

cd "$WORKDIR"

# Set the bot identity PER-CLONE (not --global): run locally, a --global config
# would silently overwrite the maintainer's own git identity.
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

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

# A rolling channel replaces its own items rather than appending. Without this
# the tip channel would add an <item> per commit to main and the feed every
# updater downloads on every check would grow without bound — and worse, the
# stale items would be LIES: a tip build's DMG is pruned off the rolling `tip`
# release once newer ones exist, so an old item's enclosure 404s. Keeping
# exactly one tip item means the only tip enclosure the feed names is the one
# that is definitely still there.
#
# (ghostty instead keeps its newest 16 tip items, which it can afford because
# its enclosures live at immutable per-commit R2 paths that are never deleted.
# On GitHub release assets there is no such immutable URL, so we keep one.)
if [[ "$ROLLING" == "true" ]]; then
  # Refuse to move the channel BACKWARDS. Runs are single-flight
  # (release-tip.yml's concurrency group), so this should be unreachable — but
  # if two runs ever did land out of order, silently republishing an older build
  # would offer every follower a downgrade they can't undo. Exit 0, not 1: it is
  # a superseded run, not a broken one.
  PREVIOUS_VERSION=$(awk -v ch="$CHANNEL" '
    /<item>/ { buf = ""; ver = ""; hit = 0; next }
    /<\/item>/ { if (hit && ver != "") print ver; next }
    {
      if (index($0, "<sparkle:channel>" ch "</sparkle:channel>")) hit = 1
      if (match($0, /<sparkle:version>[^<]*<\/sparkle:version>/)) {
        ver = substr($0, RSTART + 17, RLENGTH - 17 - 18)
      }
    }
  ' appcast.xml | LC_ALL=C sort -V | tail -1)
  if [[ -n "$PREVIOUS_VERSION" ]]; then
    NEWEST=$(printf '%s\n%s\n' "$PREVIOUS_VERSION" "$COMPARISON_VERSION" | LC_ALL=C sort -V | tail -1)
    if [[ "$COMPARISON_VERSION" == "$PREVIOUS_VERSION" || "$NEWEST" != "$COMPARISON_VERSION" ]]; then
      echo "appcast's ${CHANNEL} channel is already at ${PREVIOUS_VERSION}; refusing to publish ${COMPARISON_VERSION} over it"
      exit 0
    fi
  fi
  # Drop every existing item carrying this channel. Buffer whole <item> blocks
  # so the decision is made on the block, not a line.
  awk -v ch="$CHANNEL" '
    /<item>/ { buf = $0 ORS; in_item = 1; drop = 0; next }
    in_item {
      buf = buf $0 ORS
      if (index($0, "<sparkle:channel>" ch "</sparkle:channel>")) drop = 1
      if (index($0, "</item>")) {
        if (!drop) printf "%s", buf
        in_item = 0
      }
      next
    }
    { print }
  ' appcast.xml > appcast.xml.pruned
  mv appcast.xml.pruned appcast.xml
fi

# Insert the new <item>s before </channel> — but only if this version isn't
# already present. Re-running the workflow for the same tag (a common recovery
# action) would otherwise append a duplicate <item> for the version, leaving
# Sparkle with two entries for one release. (Sparkle picks one of a duplicated
# version arbitrarily, so the wrong pick reports an invalid signature.)
if grep -q "<sparkle:version>${COMPARISON_VERSION}</sparkle:version>" appcast.xml; then
  echo "appcast already has an entry for ${VERSION}; not inserting a duplicate"
else
  awk -v items_file="$ITEMS_FILE" '
    /<\/channel>/ {
      while ((getline line < items_file) > 0) print line
      close(items_file)
    }
    { print }
  ' appcast.xml > appcast.xml.new
  mv appcast.xml.new appcast.xml
fi

mkdir -p notes
cp "$NOTES_HTML_FILE" "$NOTES_REL_PATH"

git add appcast.xml "$NOTES_REL_PATH"
# Name the VERSION as well as the tag: a rolling tag is the same string on every
# publish, so `Publish appcast for tip` alone makes gh-pages history unreadable.
git commit -m "Publish appcast for ${TAG} (${VERSION})"
git push origin gh-pages

echo "Published appcast for ${TAG} (${VERSION})"
