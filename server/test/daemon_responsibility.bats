#!/usr/bin/env bats
# macOS attributes privacy-gated operations (Local Network, TCC) to a process's
# *responsible process*, a value fixed at spawn and inherited from the parent.
# The daemon re-execs itself disclaimed (daemonize.reexecDisclaimed) so that it,
# and not the terminal that ran `zmx attach`, is the responsible process for
# everything in the session -- and stays so after that terminal exits. These
# tests pin that contract. The semantics are Darwin-only, so they skip elsewhere.

load test_helper

# Compiles a probe around the libSystem call that reports a pid's responsible
# pid. Prints "<pid> <responsible>" per argument.
build_probe() {
  local src="$BATS_TEST_TMPDIR/rpid.c"
  cat > "$src" <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
extern pid_t responsibility_get_pid_responsible_for_pid(pid_t);
int main(int argc, char **argv) {
  for (int i = 1; i < argc; i++) {
    pid_t p = atoi(argv[i]);
    printf("%d %d\n", p, responsibility_get_pid_responsible_for_pid(p));
  }
  return 0;
}
CEOF
  cc -o "$BATS_TEST_TMPDIR/rpid" "$src"
}

responsible_for() {
  "$BATS_TEST_TMPDIR/rpid" "$1" | awk '{print $2}'
}

@test "macos: the daemon is its own responsible process and the session's programs inherit it" {
  [[ "$(uname)" == "Darwin" ]] || skip "responsibility is a macOS concept"
  command -v cc >/dev/null || skip "needs a C compiler for the responsibility probe"
  build_probe

  "$ZMX" run resp-test -d sleep 60
  wait_for_session resp-test

  # `zmx run` types the command into the shell over IPC, so the daemon's argv
  # ends at the session name.
  local daemon shell
  daemon=$(pgrep -f "__daemon resp-test$")
  [[ -n "$daemon" ]]
  shell=$(pgrep -P "$daemon")
  [[ -n "$shell" ]]

  # The daemon disclaimed the terminal that created it...
  [ "$(responsible_for "$daemon")" -eq "$daemon" ]
  # ...so the session's shell is attributed to the daemon, not to this test's own root.
  [ "$(responsible_for "$shell")" -eq "$daemon" ]
  [ "$(responsible_for $$)" -ne "$daemon" ]
}

@test "macos: the re-exec's state never reaches the session" {
  [[ "$(uname)" == "Darwin" ]] || skip "the re-exec only happens on macOS"

  # The typed command line is echoed into the history too, so the name is
  # assembled at run time: the joined string only ever appears as real output.
  "$ZMX" run leak-test -d sh -c 'env | grep ZMX_DAEMON""_ || echo no-daemon-vars'
  wait_for_session leak-test
  local i=0
  until "$ZMX" history leak-test 2>/dev/null | grep -q "no-daemon-vars"; do
    sleep 0.1
    (( i++ < 50 )) || { echo "timed out waiting for the command"; "$ZMX" history leak-test; return 1; }
  done
  run "$ZMX" history leak-test
  [[ "$output" != *"ZMX_DAEMON_"* ]]
}
