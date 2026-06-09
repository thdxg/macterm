#!/usr/bin/env bash
set -euo pipefail

BUNDLE_ID="com.thdxg.macterm.debug"
LAST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release) BUNDLE_ID="com.thdxg.macterm" ;;
    --last) LAST="$2"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

PREDICATE="subsystem == \"$BUNDLE_ID\""

if [[ -n "$LAST" ]]; then
  exec log show --predicate "$PREDICATE" --last "$LAST" --style compact
else
  exec log stream --predicate "$PREDICATE" --level debug --style compact
fi
