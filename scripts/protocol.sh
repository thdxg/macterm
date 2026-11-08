#!/usr/bin/env bash
# Write the files that the protocol schema makes (design/003 §3), or check
# them. The Zig messages in server/src/protocol/messages.zig are the source.
# The server binary's hidden `__schema` command writes:
#
#   Macterm/Protocol/MactermProtocol.generated.swift   the app's Swift types
#   server/schema/protocol.json                        the metadata
#   server/schema/frames.json                          frames for the Swift tests
#   server/schema/foreground.json                      the attach client's
#                                                      foreground APCs, for
#                                                      the Swift tests
#
# Usage:
#   scripts/protocol.sh           build the server, then write the three files
#   scripts/protocol.sh --check   fail if a file is not current, or if the
#                                 schema breaks the add-only rule against the
#                                 metadata on $PROTOCOL_BASE (origin/main), or
#                                 if a reply or an event holds a secret (CI)
#
# Needs Zig 0.17 on PATH, or in $ZIG.
set -euo pipefail

PROJECT_ROOT="$PWD"
ZIG="${ZIG:-zig}"
BASE="${PROTOCOL_BASE:-origin/main}"
METADATA=server/schema/protocol.json

check=false
for arg in "$@"; do
  case "$arg" in
    --check) check=true ;;
    *) echo "protocol.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done

(cd "$PROJECT_ROOT/server" && "$ZIG" build)
bin="$PROJECT_ROOT/server/zig-out/bin/zmx"

outputs=(
  "swift:Macterm/Protocol/MactermProtocol.generated.swift"
  "metadata:$METADATA"
  "fixtures:server/schema/frames.json"
  "foreground:server/schema/foreground.json"
)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stale=false
for entry in "${outputs[@]}"; do
  what="${entry%%:*}"
  path="${entry#*:}"
  "$bin" __schema "$what" >"$tmp/$what"
  if [[ "$check" == "true" ]]; then
    if ! diff -u "$path" "$tmp/$what"; then
      echo "protocol.sh: $path is not current. Run mise run protocol." >&2
      stale=true
    fi
  else
    mkdir -p "$(dirname "$path")"
    cp "$tmp/$what" "$path"
  fi
done

if [[ "$check" == "true" ]]; then
  [[ "$stale" == "true" ]] && exit 1
  # The metadata on the base branch. Before it has one, only the secret
  # check runs.
  if git cat-file -e "$BASE:$METADATA" 2>/dev/null; then
    git show "$BASE:$METADATA" >"$tmp/base.json"
    "$bin" __schema check "$tmp/base.json"
  else
    echo "protocol.sh: $BASE has no $METADATA. Only the secret check runs."
    "$bin" __schema check
  fi
fi
