"""Desktop widgets: terminals on the desktop, each one pane whose zmx session
persists the way a pinned tab's does.

A widget's pane is outside every workspace, so these address it the way the
widget's own shell does — by session name — and the `widget` verbs manage the
widget itself. A locked widget's terminal ignores the mouse and keyboard (a
drag moves the widget instead), not the CLI.
Clicking, dragging and edge-resizing a widget need a real pointer on the real
desktop and are not covered here; the snapping they end in is unit-tested
(`DesktopWidgetGrid`).
"""

import json
import uuid
from pathlib import Path

import pytest
from _harness import MactermHarness, wait_for

DIAG_ROOT = Path(__file__).resolve().parent.parent / "build" / "e2e" / "diagnostics"


def _widgets(app):
    return app.cli_json("widget", "list").get("widgets") or []


def _widget_text(app, session):
    """The widget pane's text, or None while its surface isn't live yet."""
    result = app.cli("pane", "dump", "--session", session, "--scrollback", "--json", check=False)
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)["dump"]["text"]


def _session_names(app):
    return {s["name"] for s in app.cli_json("session", "list").get("sessions") or []}


@pytest.fixture
def widget(app):
    # The default size, so the test pins what a bare `widget new` gives.
    info = app.cli_json("widget", "new")["widgets"][0]
    yield info
    app.cli("widget", "remove", info["id"], "--force", check=False)


def test_a_new_widget_runs_a_shell_that_takes_commands(app, widget):
    assert (widget["size"], widget["columns"], widget["rows"]) == ("3x3", 3, 3)
    assert not widget["editing"]
    wait_for(lambda: _widget_text(app, widget["session"]), timeout=60, message="the widget's shell prompt")

    nonce = uuid.uuid4().hex[:12]
    app.pane_run(f'/bin/sh -c "printf widget-%s-ok {nonce}; echo"', session=widget["session"])
    wait_for(
        lambda: f"widget-{nonce}-ok" in (_widget_text(app, widget["session"]) or ""),
        timeout=30,
        message="the command's output in the widget",
    )


def test_set_resizes_a_widget_to_a_span(app, widget):
    app.cli("widget", "set", widget["id"], "--size", "3x2")
    spanned = next(w for w in _widgets(app) if w["id"] == widget["id"])
    assert (spanned["size"], spanned["columns"], spanned["rows"]) == ("3x2", 3, 2)

    refused = app.cli("widget", "set", widget["id"], "--size", "large", check=False)
    assert refused.returncode == 1
    assert next(w for w in _widgets(app) if w["id"] == widget["id"])["size"] == "3x2"


def test_only_one_widget_is_edited_at_a_time(app, widget):
    other = app.cli_json("widget", "new", "--size", "1x1")["widgets"][0]
    try:
        app.cli("widget", "edit", widget["id"])
        assert [w["id"] for w in _widgets(app) if w["editing"]] == [widget["id"]]

        refused = app.cli("widget", "edit", other["id"], check=False)
        assert refused.returncode == 1
        assert "being edited" in refused.stderr
        assert [w["id"] for w in _widgets(app) if w["editing"]] == [widget["id"]]

        app.cli("widget", "done")
        assert not any(w["editing"] for w in _widgets(app))
        app.cli("widget", "edit", other["id"])
        assert [w["id"] for w in _widgets(app) if w["editing"]] == [other["id"]]
    finally:
        app.cli("widget", "done", check=False)
        app.cli("widget", "remove", other["id"], "--force", check=False)


def test_removing_a_widget_ends_its_session(app):
    info = app.cli_json("widget", "new", "--size", "1x1")["widgets"][0]
    wait_for(lambda: info["session"] in _session_names(app), timeout=60, message="the widget's session to start")

    app.cli("widget", "remove", info["id"], "--force")

    assert info["id"] not in {w["id"] for w in _widgets(app)}
    wait_for(
        lambda: info["session"] not in _session_names(app),
        timeout=30,
        message="the removed widget's session to end",
    )


def test_a_widget_comes_back_after_a_relaunch_on_the_same_shell(request):
    """The pinned-tab promise: quit, relaunch, and the widget is back in its
    place with the shell it had. Its own instance, since the shared one must
    not be restarted under the other tests."""
    harness = MactermHarness(request.config.getoption("--app"), home_prefix="macterm-e2e-widget-home-")
    try:
        harness.launch()
        harness.wait_for_socket()
        created = harness.cli_json("widget", "new", "--size", "2x2")["widgets"][0]
        session = created["session"]
        wait_for(lambda: _widget_text(harness, session), timeout=60, message="the widget's shell prompt")
        nonce = uuid.uuid4().hex[:12]
        # Still running at the relaunch, so a fresh shell can't fake it.
        harness.pane_run(
            f'/bin/sh -c "printf started-%s {nonce}; echo; sleep 600"',
            session=session,
        )
        wait_for(
            lambda: f"started-{nonce}" in (_widget_text(harness, session) or ""),
            timeout=30,
            message="the long-running command to start",
        )

        harness.kill()
        harness.launch()
        harness.wait_for_socket()

        restored = wait_for(lambda: _widgets(harness), timeout=30, message="the widget to be restored")
        assert [(w["id"], w["session"], w["size"]) for w in restored] == [(created["id"], session, "2x2")]
        assert (restored[0]["x"], restored[0]["y"]) == (created["x"], created["y"])
        # The reattached session replays its screen; a fresh shell would show
        # a bare prompt (the marker is assembled at runtime, so the typed
        # command line alone never contains it).
        wait_for(
            lambda: f"started-{nonce}" in (_widget_text(harness, session) or ""),
            timeout=60,
            message="the reattached widget to show the running command's output",
        )
    except Exception:
        harness.dump_diagnostics(DIAG_ROOT / request.node.name)
        raise
    finally:
        harness.cleanup()

