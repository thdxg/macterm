#!/usr/bin/env bats
# What `zmx attach` prints when it creates the session it attaches to.
#
# `zmx run` announces a new session with `session "<name>" created`; `attach`
# must not. It clears the screen right after, so the line is never meant to be
# seen, and on a terminal one row tall its newline scrolls it into scrollback,
# out of the clear's reach — a terminal that grows then shows it above the
# session's prompt.

load test_helper

# attach_output <session> <rows> <cols>: everything `zmx attach` writes to a
# pty of that size in its first second, as text.
attach_output() {
  python3 - "$ZMX" "$1" "$2" "$3" 3>&- <<'PY'
import fcntl, os, pty, signal, struct, sys, termios, time
zmx, name, rows, cols = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    os.execve(zmx, [zmx, "attach", name, "/bin/sh"], os.environ)
out, end = b"", time.time() + 1
os.set_blocking(fd, False)
while time.time() < end:
    try:
        out += os.read(fd, 65536)
    except (BlockingIOError, OSError):
        time.sleep(0.05)
os.kill(pid, signal.SIGKILL)
os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors="replace"))
PY
}

@test "attach: creating the session prints no announcement" {
  command -v python3 >/dev/null || skip "python3 needed to allocate a test PTY"
  run attach_output test-attach-quiet 1 80
  [ "$status" -eq 0 ]
  # The attach really happened: its clear reached the terminal.
  [[ "$output" == *$'\e[2J'* ]]
  [[ "$output" != *"created"* ]]
  wait_for_session test-attach-quiet
}

@test "run: creating the session still announces it" {
  run "$ZMX" run test-run-announce -d echo hello
  [ "$status" -eq 0 ]
  [[ "$output" == *"session \"test-run-announce\" created"* ]]
}
