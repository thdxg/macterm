#!/usr/bin/env bats
# CLI argument validation tests for zmx.
# See https://github.com/neurosnap/zmx/issues/178

load test_helper

# ============================================================================
# Invalid commands must exit non-zero
# ============================================================================

@test "unknown command exits non-zero" {
  run "$ZMX" foo
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "unknown command alias exits non-zero" {
  run "$ZMX" not-a-real-command
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown command"* ]]
}

@test "removed commands are unknown" {
  for cmd in run r wait w tail t print p write wr detach d print-env completions c; do
    run "$ZMX" "$cmd" dummy_session
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown command"* ]]
  done
}

@test "get with no argument outside session exits non-zero" {
  run env -u ZMX_SESSION "$ZMX" get
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "set with no argument outside session exits non-zero" {
  run env -u ZMX_SESSION "$ZMX" set
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "clear with no argument outside session exits non-zero" {
  run env -u ZMX_SESSION "$ZMX" clear
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "history with no argument outside session exits non-zero" {
  run env -u ZMX_SESSION "$ZMX" history
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "kill with no argument exits non-zero" {
  run "$ZMX" kill
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "send with no argument exits non-zero" {
  run "$ZMX" send
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

@test "attach with missing labels value exits non-zero" {
  run "$ZMX" attach --labels
  [ "$status" -ne 0 ]
  [[ "$output" == *"--labels requires"* ]]
}

# ============================================================================
# Valid commands still exit zero
# ============================================================================

@test "help exits zero" {
  run "$ZMX" help
  [ "$status" -eq 0 ]
}

@test "version exits zero" {
  run "$ZMX" version
  [ "$status" -eq 0 ]
}

