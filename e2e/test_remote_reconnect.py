"""The full #281 round trip against a REAL sshd+zmx remote — a Docker
container — proving what the unreachable-host test structurally can't: a
dropped connection keeps the pane (session alive on the host), the reconnect
trigger reattaches the SAME session with its content replayed into the
brand-new surface, and a deliberate `exit` still closes the pane (the
process-exit probe finds the session gone).

Docker-gated: skipped wherever the daemon isn't running (macOS CI runners
can't run Docker, so this is a dev-machine test; CI covers the trigger and
policy half via test_panes.py's unreachable-host test).

The pane reaches the container through the conftest ssh shim (see
`_install_ssh_shim`): OpenSSH resolves `~/.ssh/config` via the user record,
not $HOME, so the hermetic home can't carry ssh config — the shim fronts
`ssh` on the app's PATH and adds `-F <per-session config>` holding the
container's host alias, port, and throwaway key.
"""

import shutil
import socket
import subprocess
import uuid
from pathlib import Path

import pytest

from _harness import wait_for

HOST_ALIAS = "macterm-e2e-remote"
CONTAINER = "macterm-e2e-remote"
IMAGE = "macterm-e2e-remote:latest"

DOCKERFILE = """
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \\
      openssh-server ca-certificates curl procps \\
    && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd
RUN useradd -m -s /bin/bash dev
RUN ARCH=$(uname -m) \\
    && curl -fsSL "https://zmx.sh/a/zmx-0.7.0-linux-${ARCH}.tar.gz" -o /tmp/zmx.tgz \\
    && tar xzf /tmp/zmx.tgz -C /usr/local/bin && chmod 755 /usr/local/bin/zmx
COPY authorized_keys /home/dev/.ssh/authorized_keys
RUN chown -R dev:dev /home/dev/.ssh && chmod 700 /home/dev/.ssh \\
    && chmod 600 /home/dev/.ssh/authorized_keys
EXPOSE 22
CMD ["/usr/sbin/sshd", "-D", "-e"]
"""


def _docker_ready():
    if not shutil.which("docker"):
        return False
    try:
        return subprocess.run(["docker", "info"], capture_output=True, timeout=20).returncode == 0
    except subprocess.TimeoutExpired:
        return False


pytestmark = pytest.mark.skipif(
    not _docker_ready(), reason="docker unavailable (macOS CI runners can't run it)"
)


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="module")
def remote_host(app, tmp_path_factory):
    """A running sshd+zmx container, reachable as `HOST_ALIAS` through the
    app's ssh shim. Yields the alias; tears the container down after."""
    work = tmp_path_factory.mktemp("remote-host")
    key = work / "id_ed25519"
    subprocess.run(
        ["ssh-keygen", "-t", "ed25519", "-N", "", "-q", "-f", str(key)], check=True
    )
    (work / "Dockerfile").write_text(DOCKERFILE)
    (work / "authorized_keys").write_text((work / "id_ed25519.pub").read_text())
    subprocess.run(
        ["docker", "build", "-q", "-t", IMAGE, str(work)],
        check=True,
        capture_output=True,
        timeout=600,
    )
    port = _free_port()
    subprocess.run(["docker", "rm", "-f", CONTAINER], capture_output=True)
    subprocess.run(
        ["docker", "run", "-d", "--name", CONTAINER, "-p", f"127.0.0.1:{port}:22", IMAGE],
        check=True,
        capture_output=True,
    )
    config = Path(app.ssh_config_path)
    config.write_text(
        f"Host {HOST_ALIAS}\n"
        f"  HostName 127.0.0.1\n"
        f"  Port {port}\n"
        f"  User dev\n"
        f"  IdentityFile {key}\n"
        f"  IdentitiesOnly yes\n"
        f"  StrictHostKeyChecking no\n"
        f"  UserKnownHostsFile /dev/null\n"
        f"  LogLevel ERROR\n"
    )
    try:
        wait_for(
            lambda: subprocess.run(
                ["/usr/bin/ssh", "-F", str(config), "-o", "BatchMode=yes", HOST_ALIAS, "true"],
                capture_output=True,
                timeout=15,
            ).returncode
            == 0,
            timeout=60,
            message="sshd in the container accepting our key",
        )
        yield HOST_ALIAS
    finally:
        subprocess.run(["docker", "rm", "-f", CONTAINER], capture_output=True)
        config.unlink(missing_ok=True)


def _container_sessions(clients=None):
    """`zmx ls` inside the container as the dev user, parsed to
    {name: clients}. zmx's socket dir is per-user under the container's
    /tmp, so exec'ing as dev sees the pane's daemon."""
    result = subprocess.run(
        ["docker", "exec", "-u", "dev", CONTAINER, "zmx", "ls"],
        capture_output=True,
        text=True,
        timeout=20,
    )
    sessions = {}
    for raw in result.stdout.splitlines():
        line = raw.strip().removeprefix("→ ").strip()
        fields = dict(f.split("=", 1) for f in line.split("\t") if "=" in f)
        if "name" in fields:
            sessions[fields["name"]] = fields.get("clients")
    if clients is None:
        return sessions
    return {name for name, c in sessions.items() if c == str(clients)}


def _app_log(app):
    try:
        with open(app.log_stream_path) as f:
            return f.read()
    except OSError:
        return ""


def _process_exited(app, pane_id):
    """None while the surface is mid-rebuild (inspect errors then)."""
    try:
        return app.pane_inspect(pane=pane_id).get("processExited")
    except Exception:
        return None


def test_reconnect_reattaches_the_remote_session_with_its_content(app, remote_host):
    """Lid-close simulation: kill the pane's ssh client, then drive the
    `.projectSelected` reconnect trigger and prove the SAME session reattaches
    with its pre-drop content replayed into the brand-new surface."""
    projects = app.cli_json("project", "list")["projects"]
    original = next(p for p in projects if p.get("active"))
    app.cli("project", "create", f"{remote_host}:~", "--name", "e2eremote", "--select")
    try:
        pane = wait_for(lambda: app.panes(), timeout=30, message="the remote pane")[0]
        session = pane["session"]
        wait_for(
            lambda: app.pane_text(pane=pane["id"]),
            timeout=90,
            message="the remote shell's prompt (ssh + zmx attach)",
        )
        wait_for(
            lambda: session in _container_sessions(clients=1),
            timeout=30,
            message="the session attached on the host (clients=1)",
        )

        # Content that must survive: marker pushed into SCROLLBACK (zmx
        # replays scrollback as plain text — robust to surface-geometry
        # differences, unlike its visible-screen reconstruction).
        nonce = uuid.uuid4().hex[:12]
        marker = f"e2e-{nonce}-pre"
        app.pane_run(f'/bin/sh -c "printf e2e-%s-pre {nonce}; echo; seq 1 40"', pane=pane["id"])
        wait_for(
            lambda: marker in (app.pane_text(pane=pane["id"], scrollback=True) or ""),
            timeout=60,
            message=f"marker {marker} before the drop",
        )

        # Drop the connection SERVER-side (kill the per-session sshd in the
        # container): the client then exits non-zero ("closed by remote
        # host"), which is what a real network drop produces and what routes
        # to ghostty's abnormal-exit overlay. SIGTERM-ing the local client
        # instead makes ssh die BY SIGNAL, which libghostty routes to the
        # close-the-pane path — the pane vanishes and its session is killed,
        # a different (correct) behavior than a dropped connection.
        subprocess.run(
            ["docker", "exec", CONTAINER, "pkill", "-f", "sshd: dev"],
            check=True,
            timeout=20,
        )
        wait_for(
            lambda: _process_exited(app, pane["id"]) is True,
            timeout=30,
            message="the pane noticing its dead ssh (processExited)",
        )
        wait_for(
            lambda: session in _container_sessions(clients=0),
            timeout=30,
            message="the session detached but alive on the host (clients=0)",
        )

        # The reconnect trigger: select away and back.
        app.cli("project", "select", original["name"])
        app.cli("project", "select", "e2eremote")
        wait_for(
            lambda: "reconnect(projectSelected): respawning" in _app_log(app),
            timeout=30,
            message="the reconnect sweep's respawn log line",
        )

        # Same session reattached (clients back to 1) and the pre-drop marker
        # replayed into the brand-new surface.
        wait_for(
            lambda: session in _container_sessions(clients=1),
            timeout=60,
            message="the session reattached on the host (clients=1)",
        )
        wait_for(
            lambda: marker in (app.pane_text(pane=pane["id"], scrollback=True) or ""),
            timeout=60,
            message=f"marker {marker} replayed into the rebuilt surface",
        )
        panes = {p["id"]: p for p in app.panes()}
        assert panes[pane["id"]]["session"] == session

        # Deliberate end: typing `exit` ends the zmx session itself. The
        # process-exit probe confirms the session is gone on the host and
        # closes the pane — the drop above kept it precisely because the
        # session was still alive there.
        app.pane_run("exit", pane=pane["id"])
        wait_for(
            lambda: session not in _container_sessions(),
            timeout=30,
            message="the session ending on the host",
        )
        wait_for(
            lambda: pane["id"] not in {p["id"] for p in app.panes()},
            timeout=30,
            message="the pane closing after the deliberate end",
        )
    finally:
        app.cli("project", "select", original["name"], check=False)
