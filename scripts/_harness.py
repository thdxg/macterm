"""Shared harness for scripted, hermetic Macterm instances.

Extracted from benchmark.py so the resource benchmark and the e2e suite
(e2e/) launch and drive the app through one code path. The recipe — every
piece of it earned against real CI runners:

- Launch via LaunchServices (`open -n --env…`), never by exec'ing the binary:
  launch-time activation counts as user intent, so the app actually becomes
  active and SwiftUI creates its window. A directly-exec'd app starts
  backgrounded, and macOS's cooperative activation can deny post-hoc
  activation requests indefinitely on a busy desktop.
- Drive window/project state with Darwin notifications (`notifyutil -p`, the
  MACTERM_BENCHMARK=1 hook in Macterm/App/BenchmarkControl.swift) and the
  bundled `macterm` CLI over the instance's own control socket. Neither needs
  a TCC grant, so a stock headless CI runner can script the GUI app.
- Isolate the instance: a throwaway $HOME (shell rc files, ~/.config/macterm),
  MACTERM_BENCHMARK_DATA_DIR (App Support resolves via the user record, NOT
  $HOME — projects/workspaces/control.sock need the explicit override), and
  ZMX_DIR (the zmx socket dir defaults to a per-*user* path — TMPDIR/zmx-<uid>
  — that a throwaway $HOME does NOT move, so without this override a hermetic
  instance would share the session namespace with the developer's real
  Macterm: its `session list` would see their sessions, and its orphan reaper
  could kill their detached-but-persistent shells).
- Root the home in /tmp, NOT the default $TMPDIR: control.sock and the zmx
  session sockets must fit sun_path (~104 bytes), and CI runners' $TMPDIR
  (/var/folders/…/T/) pushes the paths right past that.
"""

import json
import os
import re
import shutil
import signal
import subprocess
import tempfile
import time

NOTIFY_PREFIX = "com.thdxg.macterm.bench."


class HarnessError(Exception):
    """A scripted-app operation failed. Callers decide whether that's a fatal
    CLI error (benchmark: dump diagnostics + sys.exit) or a test failure."""


def sh(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, **kwargs)


def notify(command):
    """Post a Darwin notification to every listening benchmark-mode instance."""
    sh(["notifyutil", "-p", NOTIFY_PREFIX + command])


def read_info_plist_key(app, key):
    result = sh(["defaults", "read", os.path.join(app, "Contents", "Info"), key])
    if result.returncode != 0:
        raise HarnessError(f"cannot read {key} from {app}: {result.stderr.strip()}")
    return result.stdout.strip()


def wait_for(condition, timeout=30.0, interval=0.25, message="condition"):
    """Poll `condition` until it returns a truthy value (returned) or the
    deadline passes (HarnessError). Always sleeps between polls — a fixed
    retry count with no sleep starves the app's own timers and flakes on
    loaded runners; a deadline poll survives them."""
    deadline = time.monotonic() + timeout
    while True:
        value = condition()
        if value:
            return value
        if time.monotonic() >= deadline:
            raise HarnessError(f"timed out after {timeout:.0f}s waiting for {message}")
        time.sleep(interval)


class MactermHarness:
    """One hermetic app instance: launch, drive over its control socket,
    tear down. Reusable across launches of the same home/data dir (kill()
    then launch() again) so restart scenarios can assert persistence."""

    def __init__(self, app, home_prefix="macterm-harness-home-"):
        self.app = os.path.abspath(app)
        executable = read_info_plist_key(self.app, "CFBundleExecutable")
        self.binary = os.path.join(self.app, "Contents", "MacOS", executable)
        self.bundle_id = read_info_plist_key(self.app, "CFBundleIdentifier")
        self.cli_path = os.path.join(self.app, "Contents", "Resources", "bin", "macterm")
        self.home = tempfile.mkdtemp(prefix=home_prefix, dir="/tmp")
        self.data_dir = os.path.join(self.home, "app-data")
        self.socket = os.path.join(self.data_dir, "control.sock")
        self.env = {
            "MACTERM_BENCHMARK": "1",
            "MACTERM_BENCHMARK_DATA_DIR": self.data_dir,
            "HOME": self.home,
            "ZMX_DIR": os.path.join(self.home, "zmx"),
        }
        self.pid = None
        self.log_stream = None
        self.log_stream_path = os.path.join(self.home, "app-stream.log")

    # ── Lifecycle ────────────────────────────────────────────────────────

    def launch(self, timeout=10):
        """`open -n` the app and resolve its pid. Only pids that appeared
        after this call count — a leftover instance from an aborted run (or
        the developer's own copy of the same built app) can never be adopted,
        sampled, or killed by mistake."""
        self._start_log_stream()
        preexisting = set(self._instance_pids())
        env_args = [f"--env={key}={value}" for key, value in self.env.items()]
        result = sh(["open", "-n", *env_args, self.app])
        if result.returncode != 0:
            raise HarnessError(f"open failed: {result.stderr.strip()}")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            fresh = [pid for pid in self._instance_pids() if pid not in preexisting]
            if fresh:
                self.pid = fresh[0]
                return self.pid
            time.sleep(0.5)
        raise HarnessError("app process did not appear after launch")

    def _instance_pids(self):
        """Pids whose command line starts with our exact binary path. `pgrep
        -f` treats the path as a regex (an unescaped `.` matches any char), so
        escape it and verify each candidate's real command line."""
        pids = sh(["pgrep", "-f", "--", re.escape(self.binary)]).stdout.split()
        matches = []
        for candidate in pids:
            command = sh(["ps", "-p", candidate, "-o", "command="]).stdout.strip()
            if command.startswith(self.binary):
                matches.append(int(candidate))
        return matches

    def is_alive(self):
        """False once the process is gone or a zombie. The app is launchd's
        child (launched via `open`), so it vanishes from ps on death — but a
        lingering zombie still shows up (with rss 0 and a reset cputime)."""
        if self.pid is None:
            return False
        result = sh(["ps", "-p", str(self.pid), "-o", "state="])
        state = result.stdout.strip()
        return result.returncode == 0 and bool(state) and not state.startswith("Z")

    def open_project(self, attempts=30):
        """Ask the app to open a project so a real shell + surface is on
        screen. ProjectStore.add saves projects.json into the isolated data
        dir synchronously, so its existence is the readiness marker; retry
        (idempotently) rather than sleep-and-hope, since the window this
        needs only exists once macOS granted activation."""
        marker = os.path.join(self.data_dir, "projects.json")
        for _ in range(attempts):
            notify("activate")
            notify("open-project")
            time.sleep(2)
            if not self.is_alive():
                raise HarnessError("app process died while opening the project")
            if os.path.exists(marker):
                return
        raise HarnessError(
            "app never opened a project — window creation requires app "
            "activation; is someone actively using this desktop?"
        )

    def wait_for_socket(self, attempts=30):
        """Wait until the control socket answers. It returns a `starting`
        error until AppState attaches in installResponders."""
        if not os.path.exists(self.cli_path):
            raise HarnessError("bundled macterm CLI missing from the app")
        probe = None
        for _ in range(attempts):
            probe = sh([self.cli_path, "status", "--socket", self.socket])
            if probe.returncode == 0:
                return
            time.sleep(1)
        detail = probe.stderr.strip() if probe else ""
        raise HarnessError(f"control socket never became ready: {detail}")

    def _start_log_stream(self):
        """Capture the app's unified log LIVE for its whole lifetime. The
        app logs almost everything at .info/.debug, which never persists to
        the log datastore — a post-hoc `log show` comes back empty — so
        failure forensics need a `log stream` running from before launch."""
        if self.log_stream is not None:
            return
        handle = open(self.log_stream_path, "w")
        self.log_stream = subprocess.Popen(
            [
                "log", "stream", "--style", "compact", "--info", "--debug",
                "--predicate", f'subsystem == "{self.bundle_id}"',
            ],
            stdout=handle,
            stderr=subprocess.STDOUT,
        )
        handle.close()  # Popen holds its own dup of the fd

    def kill(self):
        """SIGKILL — SIGTERM would hang on the quit-confirmation dialog for
        any running shell. zmx sessions survive by design; use
        kill_sessions() first when they shouldn't outlive the run."""
        if self.pid is None:
            return
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        self.pid = None

    def kill_sessions(self):
        """Kill every zmx session attached to one of this instance's live
        panes, so their shells don't keep running after teardown. Scoped by
        pane attachment, never by name: with a shared ZMX_DIR the daemon
        could list sessions belonging to another Macterm, and those must
        survive. Best-effort — teardown proceeds to SIGKILL regardless."""
        try:
            sessions = self.cli_json("session", "list").get("sessions") or []
            for session in sessions:
                if session.get("paneID"):
                    self.cli("session", "kill", session["name"], check=False)
        except Exception:
            pass

    def cleanup(self):
        """Full teardown: sessions (while the app can still reach zmx), the
        app process, the log stream, then the throwaway home."""
        if self.is_alive():
            self.kill_sessions()
        self.kill()
        if self.log_stream is not None:
            self.log_stream.terminate()
            self.log_stream = None
        shutil.rmtree(self.home, ignore_errors=True)

    # ── Driving the instance ─────────────────────────────────────────────

    def cli(self, *args, check=True, timeout=60):
        """Run the bundled `macterm` CLI against this instance's socket.

        `--socket` is appended AFTER the args, which is safe for every verb
        except `pane run` (its passthrough capture would swallow trailing
        flags into the typed command — and the CLI would then fall back to
        socket discovery, possibly reaching a real Macterm). Use pane_run()
        for that verb.
        """
        if not os.path.exists(self.cli_path):
            raise HarnessError("bundled macterm CLI missing from the app")
        result = sh([self.cli_path, *args, "--socket", self.socket], timeout=timeout)
        if check and result.returncode != 0:
            raise HarnessError(f"macterm {' '.join(args)} failed: {result.stderr.strip()}")
        return result

    def cli_json(self, *args):
        return json.loads(self.cli(*args, "--json").stdout)

    def pane_run(self, command, pane=None, session=None, submit=True):
        """Type `command` into a live pane's shell, with a trailing newline
        unless `submit=False` (which leaves it on the prompt). Connection and
        targeting flags are placed BEFORE the command because `pane run`
        captures everything after its first positional — see cli()."""
        args = [self.cli_path, "pane", "run", "--socket", self.socket]
        if pane:
            args += ["--pane", pane]
        if session:
            args += ["--session", session]
        if not submit:
            args.append("--no-submit")
        args.append(command)
        result = sh(args, timeout=60)
        if result.returncode != 0:
            raise HarnessError(f"macterm pane run failed: {result.stderr.strip()}")
        return result

    def panes(self, tab=None):
        args = ["pane", "list"]
        if tab:
            args += ["--tab", tab]
        return self.cli_json(*args).get("panes") or []

    def pane_inspect(self, pane=None, session=None):
        """`pane inspect`'s live terminal-core snapshot (needs a live
        surface). Caveat on `needsConfirmQuit`: it's the exact predicate the
        busy-close guard reads, but it's only an accurate idle/running signal
        where ghostty's shell integration reaches the zmx session shell (the
        fork's command-wrapper injects it per shell — nushell/zsh/fish get
        it; CI's bash 3.2 login shell has no integration and reads as
        perpetually busy). Tests that need "a program is running/idle"
        should sync on output markers via pane_text instead. The
        foreground-NAME poll (`pane list` .process) is no better a sync
        point: its zmx leader cache falls back to a 30s reconcile TTL when a
        fresh session misses the registration retry window."""
        args = ["pane", "inspect"]
        if pane:
            args += ["--pane", pane]
        if session:
            args += ["--session", session]
        return self.cli_json(*args)["inspect"]

    def pane_text(self, pane=None, scrollback=False):
        """A pane's terminal text, or None while it has no live surface yet
        (poll-friendly: `wait_for(lambda: h.pane_text(...))` also skips empty
        text, i.e. a shell that hasn't drawn its prompt)."""
        args = ["pane", "dump"]
        if scrollback:
            args.append("--scrollback")
        if pane:
            args += ["--pane", pane]
        result = self.cli(*args, "--json", check=False)
        if result.returncode != 0:
            return None
        return json.loads(result.stdout)["dump"]["text"]

    # ── Failure forensics ────────────────────────────────────────────────

    def dump_diagnostics(self, diag_dir):
        """What the app saw: a screenshot and its unified-log lines (written
        to files for CI artifacts; the log text is also returned so callers
        can print it). The log comes from the live `log stream` started at
        launch — the app logs at .info/.debug, which never persists to the
        datastore, so a post-hoc `log show` would come back empty."""
        os.makedirs(diag_dir, exist_ok=True)
        sh(["screencapture", "-x", os.path.join(diag_dir, "screen.png")])
        log_text = ""
        if os.path.exists(self.log_stream_path):
            # `log stream` batches writes; give the tail a moment to land.
            time.sleep(2)
            with open(self.log_stream_path) as f:
                log_text = f.read()
        with open(os.path.join(diag_dir, "app.log"), "w") as f:
            f.write(log_text)
        return log_text

    def dump_panes(self, diag_dir):
        """Every live pane's full text, one file per pane. Best-effort — the
        app may already be unreachable when forensics run."""
        os.makedirs(diag_dir, exist_ok=True)
        try:
            panes = self.panes()
        except Exception:
            return
        for pane in panes:
            result = self.cli("pane", "dump", "--scrollback", "--pane", pane["id"], check=False)
            text = result.stdout if result.returncode == 0 else f"<dump failed: {result.stderr}>"
            name = f"pane-tab{pane['tabIndex']}-{pane['index']}.txt"
            with open(os.path.join(diag_dir, name), "w") as f:
                f.write(text)
