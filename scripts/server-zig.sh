#!/usr/bin/env bash
# Runs `zig build` in server/ for CI (.github/workflows/server.yml). It
# recovers from two faults that are not faults of the code:
#
#   scripts/server-zig.sh fetch          fetch the packages; try 3 times
#   scripts/server-zig.sh build <args>   zig build <args>
#
# - A package fetch can fail on the network (run 42660105889: codeberg.org
#   gave a ProtocolError). `fetch` tries again. After a fetch, the packages
#   are in the global cache, and a build needs no network.
# - Zig cannot use a cache whose manifest names an output file that is not
#   there: it stops with "checking cache failed: ... FileNotFound" (run
#   42760283476). Both commands then remove the cache, except the packages
#   (`p/`), and run one more time. Any other failure is the code's, and is not
#   run again.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../server"

: "${ZIG_GLOBAL_CACHE_DIR:?ZIG_GLOBAL_CACHE_DIR is not set}"
: "${ZIG_LOCAL_CACHE_DIR:?ZIG_LOCAL_CACHE_DIR is not set}"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

clear_cache() {
  local dir
  for dir in "$ZIG_LOCAL_CACHE_DIR" "$ZIG_GLOBAL_CACHE_DIR"; do
    [[ -d "$dir" ]] && find "$dir" -mindepth 1 -maxdepth 1 ! -name p -exec rm -rf {} +
  done
}

# zig build <args>, and one more time after a cache fault.
build() {
  if zig build "$@" 2>&1 | tee "$log"; then
    return 0
  fi
  if ! grep -qE 'checking cache failed|failed to check cache' "$log"; then
    return 1
  fi
  echo "::warning::The Zig cache is not complete. Removing it, except the packages, and building again."
  clear_cache
  zig build "$@"
}

case "${1:-}" in
  fetch)
    for attempt in 1 2 3; do
      if build --fetch; then
        exit 0
      fi
      if [[ "$attempt" == 3 ]]; then
        exit 1
      fi
      echo "::warning::zig build --fetch failed (attempt $attempt of 3). Trying again."
      sleep $((attempt * 20))
    done
    ;;
  build)
    shift
    build "$@"
    ;;
  *)
    echo "usage: $0 fetch | build <zig build arguments>" >&2
    exit 2
    ;;
esac
