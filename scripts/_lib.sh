#!/usr/bin/env bash
# Shared helpers for macterm scripts

# Spinner that runs a command with a loading message.
# Output is hidden on success. On failure, stderr is printed.
# Usage: run_step "Building release..." swift build -c release
run_step() {
  local msg="$1"
  shift
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0 pid logfile

  logfile=$(mktemp)
  "$@" > "$logfile" 2>&1 &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    printf "\r  %s %s" "${frames[i++ % ${#frames[@]}]}" "$msg"
    sleep 0.08
  done

  wait "$pid"
  local status=$?
  if [[ $status -eq 0 ]]; then
    printf "\r  ✓ %s\n" "$msg"
  else
    printf "\r  ✗ %s\n" "$msg"
    cat "$logfile"
  fi
  rm -f "$logfile"
  [[ $status -eq 0 ]] || exit $status
}

# Print a step header without spinner (for interactive commands).
step() {
  printf "  → %s\n" "$1"
}
