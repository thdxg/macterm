# test_helper.bash — shared setup/teardown for zmx BATS tests

REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  ZMX="${ZMX:-$REPO_DIR/zig-out/bin/zmx}"

  # Build once per test suite (skips if already built)
  if [[ ! -x "$ZMX" ]]; then
    local os
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    local arch
    arch="$(uname -m)"
    local dist_tar
    dist_tar=$(ls -1t "$REPO_DIR/zig-out/dist/zmx-"*"-${os}-${arch}.tar.gz" 2>/dev/null | head -n1 || true)
    if [[ -n "$dist_tar" && -f "$dist_tar" ]]; then
      mkdir -p "$(dirname "$ZMX")"
      tar -xzf "$dist_tar" -C "$(dirname "$ZMX")"
    else
      cd "$REPO_DIR" && zig build
    fi
  fi

  # Inside a zmx session (a Macterm pane), attach would switch that session
  # and not create one.
  unset ZMX_SESSION

  # Isolate socket dir so tests don't interfere with real sessions or each other
  export ZMX_DIR="$BATS_TEST_TMPDIR/zmx-sockets"
  mkdir -p "$ZMX_DIR"
}

teardown() {
  # Kill any sessions created during this test
  if [[ -d "$ZMX_DIR" ]]; then
    local sessions
    sessions=$("$ZMX" list --short 2>/dev/null) || true
    if [[ -n "$sessions" ]]; then
      echo "$sessions" | xargs "$ZMX" kill --force 2>/dev/null || true
    fi
  fi
}

# start_session <name> [command...]: create a session and leave it running
# with no client. `zmx attach` needs a terminal, so it runs on a pty here.
# Once the attach has cleared the screen (raw mode is on by then), Ctrl+\
# detaches it. With no command, the session runs $SHELL.
start_session() {
  python3 - "$ZMX" "$@" 3>&- <<'PY'
import os, pty, sys, time
zmx, name, cmd = sys.argv[1], sys.argv[2], sys.argv[3:]
pid, fd = pty.fork()
if pid == 0:
    os.execv(zmx, [zmx, "attach", name] + cmd)
os.set_blocking(fd, False)
out, deadline = b"", time.time() + 10
while b"\x1b[2J" not in out:
    if time.time() > deadline:
        sys.exit("attach did not start: %r" % out)
    try:
        out += os.read(fd, 65536)
    except (BlockingIOError, OSError):
        time.sleep(0.02)
os.write(fd, b"\x1c")
while time.time() < deadline:
    done, status = os.waitpid(pid, os.WNOHANG)
    if done:
        sys.exit(os.waitstatus_to_exitcode(status))
    try:
        os.read(fd, 65536)
    except (BlockingIOError, OSError):
        time.sleep(0.02)
sys.exit("attach did not detach")
PY
  wait_for_session "$1"
}

# Helper: wait for a session to appear in list (up to N seconds)
wait_for_session() {
  local name="$1" timeout="${2:-5}" i=0
  while (( i < timeout * 10 )); do
    if "$ZMX" list --short 2>/dev/null | grep -qx "$name"; then
      return 0
    fi
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for session '$name'" >&2
  return 1
}

# Helper: wait for a marker to appear in a session's history (up to N seconds).
# Use this instead of a fixed sleep whenever a test needs the daemon to have
# processed and buffered PTY output before it checks/sends more.
wait_for_output() {
  local name="$1" marker="$2" timeout="${3:-5}" i=0
  while (( i < timeout * 10 )); do
    if "$ZMX" history "$name" 2>/dev/null | grep -qF "$marker"; then
      return 0
    fi
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for output '$marker' in session '$name'" >&2
  return 1
}

# Helper: wait for a session's cwd to match expected substring (up to N seconds).
wait_for_cwd() {
  local name="$1" pattern="$2" timeout="${3:-5}" i=0
  while (( i < timeout * 10 )); do
    if "$ZMX" list 2>/dev/null | grep -F "name=$name" | grep -qF "$pattern"; then
      return 0
    fi
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for cwd '$pattern' in session '$name'" >&2
  return 1
}
