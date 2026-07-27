"""Tab and split-tree semantics over the control plane: creation, splits,
grids, focus, and the busy-close contract."""

from _harness import wait_for


def test_new_tab_is_active_and_listed(app, fresh_tab):
    tabs = app.cli_json("tab", "list")["tabs"]
    mine = [tab for tab in tabs if tab["id"] == fresh_tab["id"]]
    assert len(mine) == 1
    assert mine[0]["active"]
    assert mine[0]["paneCount"] == 1


def test_split_creates_a_second_live_pane(app, fresh_tab, live_pane):
    app.cli("pane", "split", "--direction", "right", "--session", live_pane["session"])
    panes = app.panes(tab=fresh_tab["id"])
    assert len(panes) == 2
    new = next(pane for pane in panes if pane["id"] != live_pane["id"])
    # The split pane must come up as a real shell, not just a tree node.
    wait_for(
        lambda: app.pane_text(pane=new["id"]),
        timeout=60,
        message="the split pane's shell prompt",
    )


def test_grid_makes_two_by_two(app, fresh_tab, live_pane):
    app.cli("grid", "2x2", "--session", live_pane["session"])
    panes = app.panes(tab=fresh_tab["id"])
    assert len(panes) == 4
    # Four distinct sessions — the grid spawned three new shells, not aliases.
    assert len({pane["session"] for pane in panes}) == 4


def test_focus_moves_between_panes(app, fresh_tab, live_pane):
    app.cli("pane", "split", "--direction", "down", "--session", live_pane["session"])
    panes = app.panes(tab=fresh_tab["id"])
    assert len(panes) == 2
    # Round-trip focus across both panes and back; exactly one focused pane
    # at every step.
    for target in (panes[1], panes[0], panes[1]):
        app.cli("pane", "focus", "--session", target["session"])
        focused = [pane["session"] for pane in app.panes(tab=fresh_tab["id"]) if pane["focused"]]
        assert focused == [target["session"]]


def test_idle_tab_closes_without_force(app):
    tab = app.cli_json("tab", "new")["tabs"][0]
    pane = wait_for(lambda: app.panes(tab=tab["id"]), message="the new tab's pane")[0]
    wait_for(lambda: app.pane_text(pane=pane["id"]), timeout=60, message="an idle prompt")
    app.cli("tab", "close", tab["id"])
    assert tab["id"] not in {t["id"] for t in app.cli_json("tab", "list")["tabs"]}


def test_busy_tab_close_refused_then_forced(app, fresh_tab, live_pane, running_program):
    """The typed `busy` error is API surface: headless callers get it instead
    of the UI's confirmation dialog, and `--force` is the override. The wait
    reads the same needsConfirmQuit signal the close guard consults."""
    app.pane_run('/bin/sh -c "sleep 300"', pane=live_pane["id"])
    wait_for(
        running_program,
        timeout=60,
        message="the sleep to register as a running program",
    )

    refused = app.cli("tab", "close", fresh_tab["id"], check=False)
    assert refused.returncode == 1
    assert "running program" in refused.stderr
    assert refused.stdout == ""  # safe-fail contract: stdout only on success

    app.cli("tab", "close", fresh_tab["id"], "--force")
    assert fresh_tab["id"] not in {t["id"] for t in app.cli_json("tab", "list")["tabs"]}
