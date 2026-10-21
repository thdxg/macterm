#!/usr/bin/env bash
# Sync Macterm/Localizable.xcstrings with the strings in the source.
#
# The compiler writes the localizable strings of each Swift file to a
# .stringsdata file (SWIFT_EMIT_LOC_STRINGS). Xcode merges them into the
# catalog when you build in the IDE; xcodebuild does not. This script does the
# same merge from the command line, and it removes the entries that the source
# no longer uses, together with their translations.
#
# Usage:
#   scripts/strings.sh               build Debug, then update the catalog
#   scripts/strings.sh --no-build    use the .stringsdata of the last build
#   scripts/strings.sh --check       fail if the catalog is not in sync (CI)
set -euo pipefail

PROJECT_ROOT="$PWD"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedData"
CATALOG="$PROJECT_ROOT/Macterm/Localizable.xcstrings"
STRINGSDATA_DIR="$DERIVED_DATA/Build/Intermediates.noindex/Macterm.build/Debug/Macterm.build/Objects-normal"

build=true
check=false
for arg in "$@"; do
  case "$arg" in
    --no-build) build=false ;;
    --check) check=true ;;
    *) echo "strings.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done

if [[ "$build" == "true" ]]; then
  "$PROJECT_ROOT/scripts/setup.sh"
  xcodegen generate --spec "$PROJECT_ROOT/project.yml" >/dev/null
  xcodebuild \
    -project Macterm.xcodeproj \
    -scheme Macterm \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    build \
    | (xcbeautify --quiet 2>/dev/null || cat)
fi

# One architecture is enough: every architecture extracts the same strings.
arch_dir=$(find "$STRINGSDATA_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
if [[ -z "$arch_dir" ]]; then
  echo "strings.sh: no .stringsdata in $STRINGSDATA_DIR. Build Debug first." >&2
  exit 1
fi
args=()
for file in "$arch_dir"/*.stringsdata; do args+=(--stringsdata "$file"); done

# The table name comes from the file name, so the copy keeps it.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$CATALOG" "$work/Localizable.xcstrings"

# The sync adds new strings and marks unused ones stale. Then the stale
# entries go. The file is written in the exact format of Xcode and
# xcstringstool (` : ` separators, sorted keys, `{\n\n}` for an empty object,
# no newline at the end), so a build in the Xcode IDE does not rewrite it.
xcrun xcstringstool sync "$work/Localizable.xcstrings" "${args[@]}"
python3 -I - "$work/Localizable.xcstrings" <<'EOF'
import json, re, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    catalog = json.load(f)
catalog["strings"] = {
    key: entry for key, entry in catalog["strings"].items()
    if entry.get("extractionState") != "stale"
}
text = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "), sort_keys=True)
text = re.sub(r"(?m)^(\s*)(.*)\{\}", lambda m: m.group(1) + m.group(2) + "{\n\n" + m.group(1) + "}", text)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
EOF

if [[ "$check" == "true" ]]; then
  if ! diff -u "$CATALOG" "$work/Localizable.xcstrings"; then
    echo "Macterm/Localizable.xcstrings is not in sync with the source. Run 'mise run strings' and commit the result." >&2
    exit 1
  fi
else
  cp "$work/Localizable.xcstrings" "$CATALOG"
fi
