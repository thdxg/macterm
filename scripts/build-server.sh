#!/usr/bin/env bash
# Builds the session server in server/ for every target that Macterm carries,
# or prints the key that names such a build.
#
#   scripts/build-server.sh key          print the key of the working tree
#   scripts/build-server.sh key-of <rev> print the key of a commit
#   scripts/build-server.sh dirty        exit 0 when server/ or protocol/ has
#                                        changes that are not committed
#   scripts/build-server.sh build <dir>  build into <dir>
#
# The key is the git tree hash of server/ and protocol/ and the blob hash of
# this script, from the working tree (committed or not), hashed together. This
# script holds the Zig version and every build flag, so a change to either is
# a new key. A prebuilt named for a key is therefore the build of exactly that
# source (`macterm-<key>-<target>.tar.gz`, the `server-prebuilt` release).
#
# The build needs macOS (lipo makes the universal binary) and Zig
# $ZIG_VERSION. Zig cannot link with Xcode 26.4 or later (zig#31658), so CI
# builds on macos-15 (.github/workflows/server-build.yml).
#
# Each tarball holds one file, `zmx`: the app and the remote installer still
# call the binary by that name.
set -euo pipefail

ZIG_VERSION="0.17.1"
# The asset names of the targets, as `ZmxHostTarget` names them.
TARGETS=(universal-macos x86_64-linux aarch64-linux)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES=(server protocol scripts/build-server.sh)

existing_sources() {
  local path
  for path in "${SOURCES[@]}"; do
    [[ -e "$ROOT/$path" ]] && printf '%s\n' "$path"
  done
}

# The key from the trees of server/, protocol/ and this script.
key_from_tree() {
  local tree="$1" server protocol script
  # A commit from before this script has no build key of its own; "none"
  # gives it one that matches no prebuilt.
  server="$(git -C "$ROOT" rev-parse -q --verify "$tree:server" || echo none)"
  protocol="$(git -C "$ROOT" rev-parse -q --verify "$tree:protocol" || echo none)"
  script="$(git -C "$ROOT" rev-parse -q --verify "$tree:scripts/build-server.sh" || echo none)"
  printf 'server %s\nprotocol %s\nbuild %s\n' "$server" "$protocol" "$script" |
    shasum -a 256 | cut -c1-16
}

# The key of the working tree. For a clean tree it is the key of HEAD.
server_key() {
  local index tree
  # An empty index of our own: `git add` hashes the files as they are on
  # disk, untracked ones too, and respects .gitignore (zig-out, .zig-cache).
  index="$(mktemp -u "${TMPDIR:-/tmp}/macterm-server-index.XXXXXX")"
  local paths=()
  while IFS= read -r p; do paths+=("$p"); done < <(existing_sources)
  if ! GIT_INDEX_FILE="$index" git -C "$ROOT" add -A -- "${paths[@]}" ||
    ! tree="$(GIT_INDEX_FILE="$index" git -C "$ROOT" write-tree)"; then
    rm -f "$index"
    return 1
  fi
  rm -f "$index"
  key_from_tree "$tree"
}

is_dirty() {
  local paths=()
  while IFS= read -r p; do paths+=("$p"); done < <(existing_sources)
  [[ -n "$(git -C "$ROOT" status --porcelain -- "${paths[@]}")" ]]
}

# Tar and gzip with no owner, no time and no name in the header, so the same
# binary gives the same bytes.
package() {
  local dir="$1" out="$2"
  touch -t 200001010000 "$dir/zmx"
  tar -c -f - --uid 0 --gid 0 --uname root --gname root -C "$dir" zmx | gzip -n -9 > "$out"
  (cd "$(dirname "$out")" && shasum -a 256 "$(basename "$out")" > "$(basename "$out").sha256")
}

# Global, not local: the EXIT trap runs after build() returns, and under
# `set -u` bash 3.2 then stops on a local that is gone.
WORK=""

build() {
  local out="$1" key version upstream
  [[ "$(uname -s)" == Darwin ]] || { echo "error: the server build needs macOS (lipo)" >&2; exit 1; }
  if ! command -v zig >/dev/null 2>&1; then
    echo "error: the server build needs Zig $ZIG_VERSION, and zig is not on PATH" >&2
    exit 1
  fi
  if [[ "$(zig version)" != "$ZIG_VERSION" ]]; then
    echo "error: the server build needs Zig $ZIG_VERSION, and zig is $(zig version)" >&2
    exit 1
  fi
  key="$(server_key)"
  upstream="$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$ROOT/server/build.zig.zon")"
  [[ -n "$upstream" ]] || { echo "error: no version in server/build.zig.zon" >&2; exit 1; }
  # `zmx version` names the build. The installer compares the part after the
  # marker with the key in zmx-release.json (ZmxVersion.forkTag).
  version="${upstream}+thdxg.${key}"

  mkdir -p "$out"
  out="$(cd "$out" && pwd)"
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/macterm-server-build.XXXXXX")"
  trap 'rm -rf "$WORK"' EXIT
  local work="$WORK"

  local zig_target strip
  for zig_target in aarch64-macos x86_64-macos x86_64-linux-musl aarch64-linux-musl; do
    # Debug info stays in the Mac build, for crash reports. The Linux builds
    # go to hosts over ssh, so they are stripped.
    strip=false
    [[ "$zig_target" == *-linux-musl ]] && strip=true
    echo "Building the server for $zig_target ($version)"
    (cd "$ROOT/server" && zig build -Doptimize=ReleaseSafe -Dtarget="$zig_target" \
      -Dversion="$version" -Dstrip="$strip" --prefix "$work/$zig_target")
  done

  mkdir -p "$work/universal-macos" "$work/x86_64-linux" "$work/aarch64-linux"
  lipo -create -output "$work/universal-macos/zmx" \
    "$work/aarch64-macos/bin/zmx" "$work/x86_64-macos/bin/zmx"
  lipo "$work/universal-macos/zmx" -verify_arch arm64 x86_64
  cp "$work/x86_64-linux-musl/bin/zmx" "$work/x86_64-linux/zmx"
  cp "$work/aarch64-linux-musl/bin/zmx" "$work/aarch64-linux/zmx"
  "$work/universal-macos/zmx" version | grep -qF "$version"

  local target
  for target in "${TARGETS[@]}"; do
    package "$work/$target" "$out/macterm-$key-$target.tar.gz"
  done
  echo "Built the server $key into $out"
}

case "${1:-}" in
  key) server_key ;;
  key-of)
    [[ -n "${2:-}" ]] || { echo "usage: $0 key-of <commit>" >&2; exit 2; }
    key_from_tree "$2^{tree}"
    ;;
  dirty) is_dirty ;;
  build)
    [[ -n "${2:-}" ]] || { echo "usage: $0 build <dir>" >&2; exit 2; }
    build "$2"
    ;;
  zig-version) echo "$ZIG_VERSION" ;;
  *)
    echo "usage: $0 key | key-of <commit> | dirty | build <dir> | zig-version" >&2
    exit 2
    ;;
esac
