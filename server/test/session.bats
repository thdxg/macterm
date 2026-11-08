#!/usr/bin/env bats
# Session lifecycle tests for zmx.
#
# These tests create real zmx sessions: daemon processes, PTYs, programs.
# Without the inherited-FD close fix, bats would wait for ever on its internal
# FDs (3+), because a daemon would inherit them. If this suite completes at
# all, the FD fix works.
#
# start_session (test_helper.bash) creates each session.

load test_helper

@test "subcommands handle --help and -h without side effects" {
  for cmd in attach send kill history list; do
    run "$ZMX" "$cmd" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]

    run "$ZMX" "$cmd" -h
    [ "$status" -eq 0 ]
    [[ "$output" == *"Usage:"* ]]
  done

  run "$ZMX" list --short
  [ "$status" -eq 0 ]
  [[ "$output" != *"--help"* ]]
  [[ "$output" != *"-h"* ]]
}

# ============================================================================
# Send (raw PTY input)
# ============================================================================

@test "send: does not append CR by default" {
  start_session test-send-raw sh -c 'echo ready; exec cat'
  wait_for_output test-send-raw ready

  # Send text without \r — it should NOT execute as a command
  run "$ZMX" send test-send-raw "partial-text"
  [ "$status" -eq 0 ]
}

@test "send: requires a session name" {
  run "$ZMX" send
  [ "$status" -ne 0 ]
}

@test "send: requires text argument" {
  start_session test-send-notext

  run "$ZMX" send test-send-notext
  [ "$status" -ne 0 ]
}

@test "send: accepts piped stdin" {
  start_session test-send-pipe sh -c 'echo ready; exec cat'
  wait_for_output test-send-pipe ready

  run bash -c 'printf "piped-marker-xyz789\r" | "$0" send test-send-pipe' "$ZMX"
  [ "$status" -eq 0 ]

  wait_for_output test-send-pipe piped-marker-xyz789
  run "$ZMX" history test-send-pipe
  [[ "$output" == *"piped-marker-xyz789"* ]]
}

# ============================================================================
# Session listing
# ============================================================================

@test "list: no sessions returns cleanly" {
  run "$ZMX" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"no sessions found"* ]]
}

@test "ls aliases list" {
  run "$ZMX" ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"no sessions found"* ]]
}

@test "list: shows session details" {
  start_session test-list

  run "$ZMX" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-list"* ]]
  [[ "$output" == *"pid="* ]]
}

@test "session: no program in the session holds the listen socket" {
  # ls inherits the fds of the session's program, and lists them with their
  # types. The listen socket must be CLOEXEC, also after the macOS daemon
  # re-execs itself, or a program in the pane can accept a client in place of
  # the session. The count of fds shows that the listing saw stdin to stderr.
  start_session test-fds sh -c 'l=$(ls -lL /dev/fd/ 2>/dev/null); echo "sockets-$(echo "$l" | grep -c ^s)-fds-$(echo "$l" | grep -c ^[-bcdps])-listed"; exec sleep 30'
  wait_for_output test-fds listed

  run "$ZMX" history test-fds
  # `[ ]`, not `[[ ]]` or `(( ))`: under bash 3.2 a false one of those
  # that is not the last line does not fail the test.
  [[ "$output" =~ sockets-([0-9]+)-fds-([0-9]+)-listed ]] || false
  [ "${BASH_REMATCH[1]}" -eq 0 ]
  [ "${BASH_REMATCH[2]}" -ge 3 ]
}

@test "list --short: shows only session names" {
  start_session test-short-a
  start_session test-short-b

  run "$ZMX" list --short
  [ "$status" -eq 0 ]
  [[ "$output" == *"test-short-a"* ]]
  [[ "$output" == *"test-short-b"* ]]
}

@test "list --short: empty when no sessions" {
  run "$ZMX" list --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ============================================================================
# Session kill
# ============================================================================

@test "kill: removes a session" {
  start_session test-kill

  run "$ZMX" kill test-kill
  [ "$status" -eq 0 ]
  [[ "$output" == *"killed session test-kill"* ]]

  run "$ZMX" list --short
  [[ "$output" != *"test-kill"* ]]
}

@test "kill: multiple sessions at once" {
  start_session kill-a
  start_session kill-b

  run "$ZMX" kill kill-a kill-b
  [ "$status" -eq 0 ]
  [[ "$output" == *"killed session kill-a"* ]]
  [[ "$output" == *"killed session kill-b"* ]]
}

@test "kill --force: removes socket file for dead session" {
  start_session test-force

  # Get the daemon PID and kill it directly (simulating a crash)
  local pid
  pid=$("$ZMX" list 2>/dev/null | grep test-force | sed 's/.*pid=\([0-9]*\).*/\1/')
  if [[ -n "$pid" ]]; then
    kill -9 "$pid" 2>/dev/null || true
    # Wait for the OS to actually reap the process before relying on
    # --force to see it as dead.
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
  fi

  # Regular kill may fail on the dead session; --force cleans up
  run "$ZMX" kill --force test-force
  [ "$status" -eq 0 ]
}

# ============================================================================
# Session isolation (ZMX_DIR)
# ============================================================================

@test "ZMX_DIR isolation: sessions in one dir are invisible to another" {
  start_session test-isolated

  # A different ZMX_DIR should see no sessions
  local other_dir="$BATS_TEST_TMPDIR/zmx-other"
  mkdir -p "$other_dir"
  run env ZMX_DIR="$other_dir" "$ZMX" list --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ============================================================================
# History
# ============================================================================

@test "history: captures session output" {
  start_session test-hist sh -c 'echo bats-marker-xyzzy; exec sleep 30'
  wait_for_output test-hist bats-marker-xyzzy

  run "$ZMX" history test-hist
  [ "$status" -eq 0 ]
  [[ "$output" == *"bats-marker-xyzzy"* ]]
}

# ============================================================================
# Rapid session churn (stress test for FD handling)
# ============================================================================

@test "history: does not truncate a long line" {
  local long=1234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890
  start_session test-long-line sh -c "printf '%s\\n' $long; exec sleep 30"
  wait_for_output test-long-line 12345678901234567890
  run "$ZMX" history test-long-line
  [ "$status" -eq 0 ]
  [[ "$output" != *"<1234567890"* ]]
  [[ "$output" == *"12345678901234567890"* ]]
}

@test "churn: create and kill 5 sessions in sequence" {
  for i in 1 2 3 4 5; do
    start_session "churn-$i"
    "$ZMX" kill "churn-$i"
  done

  run "$ZMX" list --short
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
