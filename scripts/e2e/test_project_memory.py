"""Project memory: a command that finishes in a project's pane is recorded,
with its exit code, its secrets masked, and a tail of its output when it
fails. The panel's quick actions offer to run the failure again.

Recording starts at OSC 133;D (`GHOSTTY_ACTION_COMMAND_FINISHED`). CI's
bash 3.2 login shell gets no shell integration, so the script prints the
marks itself, the same bytes that shell integration sends: 133;C when the
command starts, then 133;D. libghostty drops a D that no C started
(`Surface.zig`, `stop_command` with no `command_timer`). Where the shell
does have integration, it sends a second mark for the script's own exit; the
assertions look for the script's run, so they hold in both cases.

The debug-only `project memory` verb turns recording on and reads back what
the panel would show. macOS 26 and later only: below that, the verb refuses
and the test is skipped.
"""

import os
import tempfile
import uuid

import pytest

from _harness import wait_for

SECRET = "hunter2-" + uuid.uuid4().hex[:8]
# The command-start mark, as a script's first line (see the module doc).
START = "printf '\\033]133;C\\007'\n"


def _active_project(app):
    return next(project for project in app.cli_json("project", "list")["projects"] if project["active"])


def _memory(app, project_id, *extra):
    return app.cli_json("project", "memory", project_id, *extra)["memory"]


@pytest.fixture
def recording(app):
    project = _active_project(app)
    result = app.cli("project", "memory", project["id"], "--set", "on", check=False)
    if result.returncode != 0:
        pytest.skip(f"project memory is not available: {result.stderr.strip()}")
    app.cli("project", "memory", project["id"], "--set", "forget")
    yield project
    app.cli("project", "memory", project["id"], "--set", "forget", check=False)
    app.cli("project", "memory", project["id"], "--set", "off", check=False)


def _script(body):
    """A script file, so the typed command has no quotes for the login shell
    (bash or nushell) to parse."""
    # Short, so that the typed command never wraps on the screen.
    handle, path = tempfile.mkstemp(dir="/tmp", prefix="mm-", suffix=".sh")
    with os.fdopen(handle, "w") as file:
        file.write(body)
    return path


def test_a_failed_command_is_recorded_with_its_secrets_masked(app, live_pane, recording):
    nonce = uuid.uuid4().hex[:12]
    script = _script(
        START
        + "printf 'connecting with %s\\n' \"$1\"\n"
        f"printf 'fail-{nonce}: rejected\\n'\n"
        "printf '\\033]133;D;1\\007'\n"
    )
    try:
        app.pane_run(f"/bin/sh {script} API_TOKEN={SECRET}", pane=live_pane["id"])

        def failed_entry():
            entries = _memory(app, recording["id"])["entries"]
            return next((e for e in entries if e.get("exitCode") == 1 and script in (e.get("command") or "")), None)

        entry = wait_for(failed_entry, timeout=30, message="the failed command in the project's memory")
    finally:
        os.unlink(script)

    # The secret is masked in the command and in the output tail.
    assert SECRET not in entry["command"]
    assert entry["command"].endswith("•••")
    tail = entry.get("failureTail") or ""
    assert f"fail-{nonce}: rejected" in tail
    assert SECRET not in tail
    assert "API_TOKEN=•••" in tail

    memory = _memory(app, recording["id"])
    assert memory["recording"] is True
    assert memory["unresolvedFailure"] == entry["command"]
    # A masked command is never offered to run again: the mask would be typed
    # in place of the secret.
    assert not any("•••" in action["command"] for action in memory["actions"])

    # A failure with no secret is offered to run again.
    plain = _script(START + f"printf 'plain-{nonce}\\n'\nprintf '\\033]133;D;2\\007'\n")
    try:
        app.pane_run(f"/bin/sh {plain}", pane=live_pane["id"])
        retry = wait_for(
            lambda: next((a for a in _memory(app, recording["id"])["actions"] if a["kind"] == "retry"), None),
            timeout=30,
            message="a Run Again action",
        )
    finally:
        os.unlink(plain)
    assert retry["command"] == f"/bin/sh {plain}"


def test_nothing_is_recorded_while_memory_is_off(app, live_pane, recording):
    """Absence is proven with a later command: once a run made after
    recording is back on is in the log, the earlier run's screen read is long
    past, so a missing entry for it is a real refusal, not a slow write."""
    app.cli("project", "memory", recording["id"], "--set", "off")
    nonce = uuid.uuid4().hex[:12]
    off = _script(START + f"printf 'off-{nonce}\\n'\nprintf '\\033]133;D;0\\007'\n")
    on = _script(START + f"printf 'on-{nonce}\\n'\nprintf '\\033]133;D;0\\007'\n")
    try:
        app.pane_run(f"/bin/sh {off}", pane=live_pane["id"])
        wait_for(
            lambda: f"off-{nonce}" in (app.pane_text(pane=live_pane["id"]) or ""),
            message="the first script's output",
        )
        app.cli("project", "memory", recording["id"], "--set", "on")
        app.pane_run(f"/bin/sh {on}", pane=live_pane["id"])

        def commands():
            return [e.get("command") or "" for e in _memory(app, recording["id"])["entries"]]

        wait_for(lambda: any(on in c for c in commands()), timeout=30, message="the second script in the memory")
        assert not any(off in c for c in commands())
    finally:
        os.unlink(off)
        os.unlink(on)
