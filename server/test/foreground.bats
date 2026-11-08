#!/usr/bin/env bats
# Foreground reports (src/foreground.zig): a client started with
# ZMX_FOREGROUND_EVENTS gets the foreground process of the session's pty.

load test_helper

setup_file() {
  export PYTHONPATH="$BATS_TEST_DIRNAME"
}

# On macOS, KERN_PROCARGS2 holds the environment after the arguments, and a
# buffer that is too short gets the end of that data. The foreground here is
# a nested `zmx attach`, because the kernel shows no environment for a
# platform binary such as /bin/sleep.
@test "foreground: a process with an environment over 8 KB reports its args" {
  command -v python3 >/dev/null || skip "python3 needed to allocate test PTYs"
  export ZMX
  big=$(printf 'x%.0s' $(seq 16384))
  start_session outer /usr/bin/env -u ZMX_SESSION "BIG=$big" "$ZMX" attach inner /bin/sleep 300
  wait_for_session inner
  ZMX_FOREGROUND_EVENTS=1 python3 - <<'PY'
import os
from ptyrun import Pty
p = Pty([os.environ["ZMX"], "attach", "outer"])
p.wait_output("zmx;foreground;")
p.wait_output("attach inner /bin/sleep 300\x1b\\")
PY
}
