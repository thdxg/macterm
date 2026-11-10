#!/usr/bin/env bats
# The check, the install and the attach on a host (host/attach.sh,
# host/install.sh, design/005 steps 3 to 5), over a real sshd on this
# machine, as the app sends them: `sh -c '<script>' macterm <args>` as the
# ssh command, joined into one line. Two builds of the server, with the build keys aaaa1111 and
# bbbb2222, stand for two app versions. The app's half (the consent, the
# replace) is in MactermTests/Server/RemoteServersTests.swift. The last test
# runs remote panes as the app does (0057, RemoteHosts): each pane is an ssh
# channel over one master.

load test_helper

A=aaaa1111
B=bbbb2222

setup_file() {
  export PYTHONPATH="$BATS_TEST_DIRNAME"
  # No skip: a missing sshd fails the file (CI installs it on Linux).
  [[ -x /usr/sbin/sshd ]]
  local key
  for key in $A $B; do
    (cd "$REPO_DIR" && zig build -Dversion="1.0.1+thdxg.$key" -p "$BATS_FILE_TMPDIR/$key")
    gzip -n -c "$BATS_FILE_TMPDIR/$key/bin/zmx" >"$BATS_FILE_TMPDIR/$key.gz"
  done
}

setup() {
  # Short: a socket path has at most 103 bytes on macOS.
  T="$(mktemp -d "${TMPDIR:-/tmp}/hi.XXXXXX")"
  HOST_HOME="$T/home"
  export MACTERM_RUNTIME_DIR="$T/run"
  mkdir -p "$HOST_HOME"
  ssh-keygen -q -t ed25519 -N "" -f "$T/host_key"
  ssh-keygen -q -t ed25519 -N "" -f "$T/user_key"
  cp "$T/user_key.pub" "$T/authorized_keys"
  local port
  port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  cat >"$T/sshd_config" <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $T/host_key
AuthorizedKeysFile $T/authorized_keys
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PidFile $T/sshd.pid
SetEnv HOME=$HOST_HOME MACTERM_RUNTIME_DIR=$MACTERM_RUNTIME_DIR SHELL=/bin/sh
EOF
  cat >"$T/ssh_config" <<EOF
Host box
  HostName 127.0.0.1
  Port $port
  IdentityFile $T/user_key
  IdentitiesOnly yes
  StrictHostKeyChecking no
  UserKnownHostsFile /dev/null
  LogLevel ERROR
EOF
  /usr/sbin/sshd -f "$T/sshd_config" -E "$T/sshd.log"
  local i=0
  until grep -q "Server listening" "$T/sshd.log" 2>/dev/null; do
    ((i++ < 100)) || {
      cat "$T/sshd.log"
      return 1
    }
    sleep 0.05
  done
  export T HOST_HOME
}

teardown() {
  local sock pid
  [[ -S "$T/cm" ]] && ssh -F "$T/ssh_config" -S "$T/cm" -O exit box 2>/dev/null || true
  if [[ -S "$MACTERM_RUNTIME_DIR/.server" ]]; then
    pid=$(python3 "$BATS_TEST_DIRNAME/v2client.py" server-pid 2>/dev/null) && kill -KILL "$pid" 2>/dev/null || true
  fi
  for sock in "$MACTERM_RUNTIME_DIR"/*; do
    [[ -S "$sock" ]] || continue
    pid=$(python3 "$BATS_TEST_DIRNAME/v2client.py" pid "$(basename "$sock")" 2>/dev/null) || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  [[ -f "$T/sshd.pid" ]] && kill "$(cat "$T/sshd.pid")" 2>/dev/null || true
  rm -rf "$T"
}

sha() {
  if command -v sha256sum >/dev/null; then sha256sum <"$1"; else shasum -a 256 <"$1"; fi | cut -d" " -f1
}

# A host script as the app sends it: no comment lines, the lines joined
# with spaces (HostScripts.oneLine).
one_line() {
  grep -v '^[[:space:]]*#' "$REPO_DIR/host/$1" | sed 's/^[[:space:]]*//' | grep -v '^$' | tr '\n' ' ' | sed 's/ $//'
}

# The ssh command of the app's check and attach for the build `$1`.
attach_command() {
  printf "sh -c '%s' macterm %s" "$(one_line attach.sh)" "$1"
}

keys_checksum() {
  cat /etc/ssh/ssh_host_*_key.pub 2>/dev/null | cut -d " " -f 1-2 | sort | cksum | cut -d " " -f 1
}

check_host() {
  ssh -F "$T/ssh_config" box "$(attach_command "$1")" </dev/null
}

# install_build <key> <host id>: the app's install, with the build on stdin.
install_build() {
  local gz="$BATS_FILE_TMPDIR/$1.gz" bin="$BATS_FILE_TMPDIR/$1/bin/zmx"
  ssh -F "$T/ssh_config" box \
    "$(printf "sh -c '%s' macterm %s %s %s" "$(one_line install.sh)" "$1" "$(sha "$bin")" "$2")" <"$gz"
}

# relay <key>: python code on stdin runs with `c`, a RelayClient whose stream
# is the ssh command of the check and attach for the build `<key>`.
relay() {
  ATTACH_COMMAND="${NOISE:-}$(attach_command "$1")" python3 -c '
import os, sys
from v2client import RelayClient
c = RelayClient(argv=["ssh", "-F", os.environ["T"] + "/ssh_config", "box", os.environ["ATTACH_COMMAND"]], skip_to=b"macterm-host proxy\n")
c.wait(lambda: c.control, what="hello")
exec(sys.stdin.read())
c.close()
'
}

@test "host: the first connect finds no server, and the install puts it in place" {
  run check_host $A
  [ "$status" -eq 3 ]
  [[ "$output" == "macterm-host missing $(uname -s) $(uname -m) - $(keys_checksum)" ]]
  # The check writes nothing on the host.
  [ ! -e "$HOST_HOME/.local" ]

  run install_build $A first-id
  [ "$status" -eq 0 ]
  [ "$output" = "macterm-host installed first-id" ]
  local file="$HOST_HOME/.local/share/macterm/bin/macterm-$A"
  [ -x "$file" ]
  [ "$(ls -l "$file" | cut -c1-10)" = "-rwx------" ]
  [ "$(readlink "$HOST_HOME/.local/bin/macterm")" = "$file" ]
  # No temp file stays.
  [ "$(ls -A "$HOST_HOME/.local/share/macterm/bin")" = "macterm-$A" ]

  relay $A <<'PY'
hello = c.control[0]
assert hello["role"] == "server", hello
assert hello["build"] == "1.0.1+thdxg.aaaa1111", hello
assert c.call("ping") == {}
PY
}

@test "host: a current host answers the first command with the server's hello" {
  install_build $A first-id
  # One ssh command, and the first frame is the server's hello: no second
  # round trip for a check.
  relay $A <<'PY'
assert c.control[0]["build"] == "1.0.1+thdxg.aaaa1111", c.control[0]
PY
  relay $A <<'PY'
assert c.control[0]["build"] == "1.0.1+thdxg.aaaa1111", c.control[0]
PY
}

@test "host: an update replaces the server, keeps the old session, and removes the old file after it" {
  install_build $A first-id
  relay $A <<'PY'
c.call("session.create", id="old", command=[b"/bin/sh"])
PY
  run check_host $B
  [ "$status" -eq 3 ]
  # The host id of the first install stays.
  [[ "$output" == "macterm-host missing $(uname -s) $(uname -m) first-id $(keys_checksum)" ]]
  run install_build $B other-id
  [ "$status" -eq 0 ]
  [ "$output" = "macterm-host installed first-id" ]
  [ "$(readlink "$HOST_HOME/.local/bin/macterm")" = "$HOST_HOME/.local/share/macterm/bin/macterm-$B" ]

  # The new proxy reaches the old server first. The app tells it to exit
  # and connects again.
  relay $B <<'PY'
assert c.control[0]["build"] == "1.0.1+thdxg.aaaa1111", c.control[0]
assert c.call("server.exit") == {}
PY
  relay $B <<'PY'
import os, time
assert c.control[0]["build"] == "1.0.1+thdxg.bbbb2222", c.control[0]
sessions = c.call("session.list")["sessions"]
old = [s for s in sessions if s["id"] == "old"]
assert old and old[0]["state"] == "running" and old[0]["build"] == "1.0.1+thdxg.aaaa1111", sessions
bin = os.environ["HOST_HOME"] + "/.local/share/macterm/bin/"
# The old session runs the old build: its file stays.
assert os.path.exists(bin + "macterm-aaaa1111")
# A file of the last minute stays too (a proxy may still come): make it old.
os.utime(bin + "macterm-aaaa1111", (time.time() - 120, time.time() - 120))
c.call("session.kill", id="old")
deadline = time.time() + 10
while os.path.exists(bin + "macterm-aaaa1111"):
    assert time.time() < deadline, "the old build stayed"
    c.pump(0.1)
assert os.listdir(bin) == ["macterm-bbbb2222"], os.listdir(bin)
PY
}

@test "host: a new home gets a new host id, and an install never changes one" {
  install_build $A first-id
  [ "$(cat "$HOST_HOME/.local/share/macterm/host-id")" = first-id ]
  run install_build $A other-id
  [ "$output" = "macterm-host installed first-id" ]
  # Another machine behind the same name: no files, so no host id.
  rm -rf "$HOST_HOME/.local"
  run check_host $A
  [ "$status" -eq 3 ]
  [[ "$output" == "macterm-host missing $(uname -s) $(uname -m) - $(keys_checksum)" ]]
  run install_build $A second-id
  [ "$output" = "macterm-host installed second-id" ]
}

@test "host: a wrong checksum installs nothing" {
  run ssh -F "$T/ssh_config" box \
    "$(printf "sh -c '%s' macterm %s %s %s" "$(one_line install.sh)" $A 0000 first-id)" <"$BATS_FILE_TMPDIR/$A.gz"
  [ "$status" -eq 5 ]
  [[ "$output" == *"the checksum does not match"* ]]
  [ -z "$(ls -A "$HOST_HOME/.local/share/macterm/bin")" ]
  run check_host $A
  [ "$status" -eq 3 ]
}

@test "host: a file of the user at ~/.local/bin/macterm stays" {
  mkdir -p "$HOST_HOME/.local/bin"
  echo mine >"$HOST_HOME/.local/bin/macterm"
  run install_build $A first-id
  [ "$status" -eq 0 ]
  [ "$(cat "$HOST_HOME/.local/bin/macterm")" = mine ]
}

@test "host: text that a shell rc file writes before the proxy is dropped" {
  install_build $A first-id
  # As a ~/.bashrc that prints: the login shell writes it before the command.
  NOISE="echo hello from an rc file;" relay $A <<'PY'
assert c.control[0]["build"] == "1.0.1+thdxg.aaaa1111", c.control[0]
PY
}

# A remote pane's command (RemoteSpawn.sessionCommand) for the session $1:
# the host server's own client of the session. "create" makes a missing
# session in the home folder; an attach never makes one.
pane_command() {
  local s="ZMX_FOREGROUND_EVENTS=1; export ZMX_FOREGROUND_EVENTS; b=\"\$HOME/.local/share/macterm/bin/macterm-$A\"; [ -x \"\$b\" ] || exit 255; "
  if [[ "${2:-}" == create ]]; then
    s+="cd; exec \"\$b\" connect \"$1\" --"
  else
    s+="exec \"\$b\" connect \"$1\""
  fi
  printf "sh -c '%s'" "$s"
}

@test "host: panes over one connection cost one login, report the foreground and attach again after a drop" {
  install_build $A pane-id
  ssh -F "$T/ssh_config" -M -N -f -S "$T/cm" -o ControlPersist=yes box
  ONE="$(pane_command one create)" TWO="$(pane_command two create)" AGAIN="$(pane_command one)" python3 - <<'PY'
import os, subprocess
from ptyrun import Pty
T = os.environ["T"]
ssh = ["ssh", "-F", T + "/ssh_config", "-S", T + "/cm"]

def pane(command):
    # SSHConnections.ttyArguments: never a login of its own.
    return Pty(["/usr/bin/env"] + ssh + ["-o", "ControlMaster=no", "-o", "BatchMode=yes",
               "-o", "ProxyCommand=/usr/bin/false", "-q", "-t", "box", command])

one = pane(os.environ["ONE"])
two = pane(os.environ["TWO"])
for p, name in ((one, "one"), (two, "two")):
    p.type("printf 'ready-%s\\n' " + name + "\n")
    p.wait_output("ready-" + name)

# The host pushes the session's foreground into the pane's output: the
# report ends with the program's command line.
one.type("sleep 60\n")
one.wait_output("sleep 60\x1b\\")

# The connection drops: each channel's ssh exits 255, and the sessions stay.
subprocess.run(ssh + ["-O", "exit", "box"], check=True, capture_output=True)
assert one.wait_exit() == 255, one.status
assert two.wait_exit() == 255, two.status

# A new connection: the pane attaches to its session, which replays its screen.
subprocess.run(ssh + ["-M", "-N", "-f", "-o", "ControlPersist=yes", "box"], check=True)
again = pane(os.environ["AGAIN"])
again.wait_output("ready-one")
again.wait_output("sleep 60")
os.kill(again.pid, 9)
PY
  [ "$(grep -c 'Accepted publickey' "$T/sshd.log")" -eq 2 ]
}

@test "host: an attach to a session that is not there makes none" {
  install_build $A pane-id
  run ssh -F "$T/ssh_config" -tt box "$(pane_command gone)" </dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *'no session "gone"'* ]]
}
