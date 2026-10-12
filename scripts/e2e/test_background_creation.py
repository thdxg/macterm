"""CLI no-focus creation starts real shells without visiting the child."""

import json
import uuid

import pytest

from _harness import wait_for


def _selection(app):
    return [
        (w["id"], w.get("projectID"), w.get("tabID"), w["focused"])
        for w in app.cli_json("window", "list")["windows"]
    ]


def _has_output(app, session, marker):
    result = app.cli("pane", "dump", "--session", session, "--scrollback", "--json", check=False)
    return result.returncode == 0 and marker in json.loads(result.stdout)["dump"]["text"]


@pytest.mark.parametrize("initial_command", [False, True])
def test_background_tab_starts_without_selection(app, fresh_tab, live_pane, initial_command):
    before = _selection(app)
    nonce = uuid.uuid4().hex[:12]
    command = f'/bin/sh -c "printf background-%s {nonce}; echo"'
    flags = ["--run", command] if initial_command else []
    child = app.cli_json("tab", "new", "--no-focus", *flags)["tabs"][0]
    assert not child["active"]
    pane = app.panes(tab=child["id"])[0]
    if not initial_command:
        wait_for(lambda: app.pane_text(pane=pane["id"]), timeout=60, message="the hidden shell prompt")
        app.pane_run(command, session=pane["session"])

    def completed_without_focus_change():
        assert _selection(app) == before
        assert next(t["id"] for t in app.cli_json("tab", "list")["tabs"] if t["active"]) == fresh_tab["id"]
        return _has_output(app, pane["session"], f"background-{nonce}")

    wait_for(completed_without_focus_change, timeout=60, message="the background command to execute")
    # Closing the child must not disturb the parent either.
    app.cli("tab", "close", child["id"], "--force")
    assert _selection(app) == before


@pytest.mark.parametrize("visibility", ["visible", "hidden_tab", "zoomed"])
def test_no_focus_split_starts_even_when_hidden(app, fresh_tab, live_pane, visibility):
    hidden_tab = visibility == "hidden_tab"
    if hidden_tab:
        app.cli("tab", "new")
    elif visibility == "zoomed":
        app.cli("pane", "zoom", "--session", live_pane["session"])
    before = _selection(app)
    nonce = uuid.uuid4().hex[:12]
    child = app.cli_json(
        "pane", "split", "--session", live_pane["session"], "--direction", "down", "--no-focus",
        "--run", f'/bin/sh -c "printf split-%s {nonce}; echo"',
    )["panes"][0]
    assert not child["focused"]

    def completed_without_focus_change():
        assert _selection(app) == before
        focused = [p["id"] for p in app.panes(tab=fresh_tab["id"]) if p["focused"]]
        assert focused == ([] if hidden_tab else [live_pane["id"]])
        return _has_output(app, child["session"], f"split-{nonce}")

    wait_for(completed_without_focus_change, timeout=60, message="the unfocused split command to execute")
    if hidden_tab:
        # The wire focused marker also requires the TAB to be active. On a
        # later explicit visit, the source must still be its remembered focus.
        app.cli("tab", "select", fresh_tab["id"])
        assert [p["id"] for p in app.panes(tab=fresh_tab["id"]) if p["focused"]] == [live_pane["id"]]


def test_no_focus_split_starts_when_last_window_is_hidden(app, fresh_tab, live_pane):
    windows = app.cli_json("window", "list")["windows"]
    assert len(windows) == 1
    window_id = windows[0]["id"]
    app.cli("window", "close", "--window", window_id)
    try:
        # Closing the sole window orders it out, but leaves it registered as
        # this tab's owner. Ownership must not strand the child's startup.
        assert [w["id"] for w in app.cli_json("window", "list")["windows"]] == [window_id]
        nonce = uuid.uuid4().hex[:12]
        child = app.cli_json(
            "pane", "split", "--session", live_pane["session"], "--no-focus",
            "--run", f'/bin/sh -c "printf hidden-window-%s {nonce}; echo"',
        )["panes"][0]
        assert not child["focused"]
        wait_for(
            lambda: _has_output(app, child["session"], f"hidden-window-{nonce}"),
            timeout=30,
            message="the no-focus split to execute while its owner window is hidden",
        )
        assert [p["id"] for p in app.panes(tab=fresh_tab["id"]) if p["focused"]] == [live_pane["id"]]
    finally:
        app.cli("window", "focus", window_id)


@pytest.mark.parametrize("split", [False, True])
def test_background_shell_exit_removes_the_never_viewed_child(app, fresh_tab, live_pane, split):
    before = _selection(app)
    tab = app.cli_json("tab", "new", "--no-focus")["tabs"][0]
    source = app.panes(tab=tab["id"])[0]
    child = source
    if split:
        child = app.cli_json("pane", "split", "--session", source["session"], "--no-focus")["panes"][0]
    wait_for(lambda: app.pane_text(pane=child["id"]), timeout=60, message="the hidden child's prompt")
    # Ghostty deliberately retains a surface whose command exits within its
    # abnormal-command-exit-runtime window (250ms): it shows a launch-failure
    # overlay instead of issuing close_surface. Exercise a normal exit by
    # running a short workload first, not by racing the shell's startup.
    app.pane_run('/bin/sh -c "sleep 1"; exit', session=child["session"])

    def child_closed_without_a_visit():
        assert _selection(app) == before
        tabs = app.cli_json("tab", "list")["tabs"]
        if not split:
            return all(t["id"] != tab["id"] for t in tabs)
        assert any(t["id"] == tab["id"] for t in tabs)
        return [p["id"] for p in app.panes(tab=tab["id"])] == [source["id"]]

    wait_for(child_closed_without_a_visit, timeout=60, message="the hidden shell exit to close its pane")


def test_no_focus_first_tab_in_empty_project_is_visible(app, fresh_tab, tmp_path):
    original_project = app.cli_json("status")["status"]["activeProjectID"]
    project = app.cli_json(
        "project", "create", str(tmp_path), "--name", f"empty-{uuid.uuid4().hex[:8]}", "--select",
    )["projects"][0]
    try:
        for tab in app.cli_json("tab", "list", "--project", project["id"])["tabs"]:
            app.cli("tab", "close", tab["id"], "--project", project["id"], "--force")
        nonce = uuid.uuid4().hex[:12]
        child = app.cli_json(
            "tab", "new", "--project", project["id"], "--no-focus",
            "--run", f'/bin/sh -c "printf adopted-%s {nonce}; echo"',
        )["tabs"][0]
        assert child["active"]
        pane = app.panes(tab=child["id"])[0]

        def adopted_and_running():
            windows = app.cli_json("window", "list")["windows"]
            assert any(w.get("projectID") == project["id"] and w.get("tabID") == child["id"] for w in windows)
            return _has_output(app, pane["session"], f"adopted-{nonce}")

        wait_for(adopted_and_running, timeout=60, message="the empty project's first tab to be visible and running")
    finally:
        app.cli("project", "select", original_project)
        app.cli("project", "remove", project["id"], "--force", check=False)


def test_background_creation_leaves_another_project_window_alone(app, fresh_tab, live_pane, tmp_path):
    original_project = app.cli_json("status")["status"]["activeProjectID"]
    original_windows = {w[0] for w in _selection(app)}
    other = app.cli_json("project", "create", str(tmp_path), "--name", f"background-{uuid.uuid4().hex[:8]}")["projects"][0]
    try:
        app.cli("window", "new")
        new_window = wait_for(
            lambda: next((w[0] for w in _selection(app) if w[0] not in original_windows), None),
            message="the second window",
        )
        app.cli("project", "select", other["id"], "--window", new_window)
        app.cli("window", "focus", new_window)
        wait_for(
            lambda: app.cli_json("status")["status"].get("activeProjectID") == other["id"],
            message="the other project to become active",
        )
        before = _selection(app)
        tab = app.cli_json("tab", "new", "--project", original_project, "--no-focus")["tabs"][0]
        assert not tab["active"]
        pane = app.cli_json("pane", "list", "--project", original_project, "--tab", tab["id"])["panes"][0]
        # Split a NEVER-VIEWED tab, addressed by session while another project
        # is active. Both surfaces must start, with neither window switching.
        nonce = uuid.uuid4().hex[:12]
        child = app.cli_json(
            "pane", "split", "--session", pane["session"], "--no-focus",
            "--run", f'/bin/sh -c "printf elsewhere-%s {nonce}; echo"',
        )["panes"][0]
        assert not child["focused"]

        def completed_without_focus_change():
            assert _selection(app) == before
            return _has_output(app, child["session"], f"elsewhere-{nonce}")

        wait_for(completed_without_focus_change, timeout=60, message="the never-viewed split to execute")
    finally:
        for window in _selection(app):
            if window[0] not in original_windows:
                app.cli("window", "close", "--window", window[0], check=False)
        app.cli("project", "select", original_project)
        app.cli("project", "remove", other["id"], "--force", check=False)
