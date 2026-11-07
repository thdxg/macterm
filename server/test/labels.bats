#!/usr/bin/env bats
# Label tests for zmx.

load test_helper

# ============================================================================
# Label CRUD
# ============================================================================

@test "set/get: round-trips labels" {
  start_session test-labels sleep 30

  run "$ZMX" set test-labels project=zmx env=dev
  [ "$status" -eq 0 ]

  run "$ZMX" get test-labels
  [ "$status" -eq 0 ]
  [[ "$output" == *"env=dev"* ]]
  [[ "$output" == *"project=zmx"* ]]
}

@test "set: updates existing label" {
  start_session test-update sleep 30

  run "$ZMX" set test-update status=busy
  [ "$status" -eq 0 ]
  run "$ZMX" set test-update status=done
  [ "$status" -eq 0 ]

  run "$ZMX" get test-update
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=done"* ]]
  [[ "$output" != *"status=busy"* ]]
}

@test "set: rejects reserved key 'name'" {
  start_session test-reserved sleep 30

  run "$ZMX" set test-reserved name=bad
  [ "$status" -ne 0 ]
  [[ "$output" == *"read-only built-in field"* ]]
}

@test "set: rejects reserved key 'start_dir'" {
  start_session test-reserved2 sleep 30

  run "$ZMX" set test-reserved2 start_dir=/tmp
  [ "$status" -ne 0 ]
  [[ "$output" == *"read-only built-in field"* ]]
}

@test "set: rejects reserved key 'cmd'" {
  start_session test-reserved3 sleep 30

  run "$ZMX" set test-reserved3 cmd=bad
  [ "$status" -ne 0 ]
  [[ "$output" == *"read-only built-in field"* ]]
}

@test "set with empty value removes label" {
  start_session test-unset sleep 30

  run "$ZMX" set test-unset a=1 b=2
  run "$ZMX" set test-unset a=

  run "$ZMX" get test-unset
  [ "$status" -eq 0 ]
  [[ "$output" != *"a=1"* ]]
  [[ "$output" == *"b=2"* ]]
}

@test "clear: removes all labels" {
  start_session test-clear sleep 30

  run "$ZMX" set test-clear x=1 y=2
  run "$ZMX" clear test-clear

  run "$ZMX" get test-clear
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "clear: cl alias works" {
  start_session test-clear-alias sleep 30

  run "$ZMX" set test-clear-alias x=1 y=2
  run "$ZMX" cl test-clear-alias
  [ "$status" -eq 0 ]

  run "$ZMX" get test-clear-alias
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "set: missing key-value pairs exits non-zero" {
  start_session test-nokv sleep 30

  run "$ZMX" set test-nokv
  [ "$status" -ne 0 ]
  [[ "$output" == *"key=value"* ]]
}

@test "get: missing key in existing session exits non-zero" {
  start_session test-getkey sleep 30

  run "$ZMX" set test-getkey a=1
  run "$ZMX" get test-getkey b
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "get: no session prints error" {
  run "$ZMX" get nonexistent
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "get: no args prints error" {
  run env -u ZMX_SESSION "$ZMX" get
  [ "$status" -ne 0 ]
  [[ "$output" == *"session name required"* ]]
}

