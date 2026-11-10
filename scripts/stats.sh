#!/usr/bin/env bash
set -euo pipefail

REPO="macterm/macterm"

releases_json=$(gh api --paginate "repos/${REPO}/releases")

total=$(jq -r '[.[].assets[] | select(.name | endswith(".dmg")) | .download_count] | add // 0' <<<"$releases_json")

latest=$(jq -r '
  [.[] | select(.draft == false and .prerelease == false and (.assets | length) > 0)]
  | sort_by(.published_at) | reverse | .[0]
  | {tag: .tag_name, published: .published_at, downloads: ([.assets[] | select(.name | endswith(".dmg")) | .download_count] | add // 0)}
' <<<"$releases_json")

latest_tag=$(jq -r '.tag' <<<"$latest")
latest_pub=$(jq -r '.published' <<<"$latest")
latest_dl=$(jq -r '.downloads' <<<"$latest")

printf "Macterm install counts (%s)\n" "$REPO"
printf "  Total DMG downloads:  %s\n" "$total"
printf "  Latest release:       %s (published %s)\n" "$latest_tag" "$latest_pub"
printf "  Downloads on latest:  %s  (≈ active install floor)\n" "$latest_dl"
echo
echo "Per-release breakdown (newest first):"
jq -r '
  .[] | select(.assets | length > 0)
  | "  \(.tag_name)\t\(.published_at[:10])\t\([.assets[] | select(.name | endswith(".dmg")) | .download_count] | add // 0)"
' <<<"$releases_json" | column -t -s $'\t'
