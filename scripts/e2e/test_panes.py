"""Tab and split-tree semantics over the control plane: creation, splits,
grids, focus, and the busy-close contract."""

import uuid

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


def test_focus_direction_moves_from_the_origin_and_no_ops_at_the_edge(app, fresh_tab, live_pane):
    """`pane focus --direction` is the half of a vim-tmux-navigator-style keymap
    that lives outside the editor: the plugin calls it only after failing to
    move within its own splits, so the edge case is API surface. No neighbour
    that way must exit 0 and report the origin unchanged — a plugin tells
    "didn't move" from "failed" by comparing the reported session, not by
    parsing an error."""
    app.cli("pane", "split", "--direction", "down", "--session", live_pane["session"])
    panes = app.panes(tab=fresh_tab["id"])
    assert len(panes) == 2
    top, bottom = panes[0], panes[1]

    # Up from the bottom pane lands on the top one, and says so.
    moved = app.cli_json("pane", "focus", "--direction", "up", "--session", bottom["session"])
    assert moved["panes"][0]["session"] == top["session"]
    focused = [pane["session"] for pane in app.panes(tab=fresh_tab["id"]) if pane["focused"]]
    assert focused == [top["session"]]

    # Already topmost: still ok, focus unchanged, origin reported back.
    edge = app.cli_json("pane", "focus", "--direction", "up", "--session", top["session"])
    assert edge["panes"][0]["session"] == top["session"]
    focused = [pane["session"] for pane in app.panes(tab=fresh_tab["id"]) if pane["focused"]]
    assert focused == [top["session"]]

    # Down from the top pane goes back — the direction isn't one-way.
    back = app.cli_json("pane", "focus", "--direction", "down", "--session", top["session"])
    assert back["panes"][0]["session"] == bottom["session"]


def test_tab_move_places_tab_at_its_final_slot(app, fresh_tab):
    """`tab move` speaks final positions: the slot argument is where the tab
    ends up in `tab list` order, in both directions — no drag-and-drop offset
    arithmetic leaks to the caller."""
    second = app.cli_json("tab", "new")["tabs"][0]
    tabs = app.cli_json("tab", "list")["tabs"]
    fresh_slot = next(t["index"] for t in tabs if t["id"] == fresh_tab["id"])

    # Move the newest tab up into the fresh tab's slot; the pair swaps.
    moved = app.cli_json("tab", "move", second["id"], str(fresh_slot))["tabs"][0]
    assert moved["index"] == fresh_slot
    after = app.cli_json("tab", "list")["tabs"]
    assert [t["id"] for t in after[fresh_slot - 1 : fresh_slot + 1]] == [second["id"], fresh_tab["id"]]

    # And back down toward the end — the direction that needs the coordinate
    # conversion server-side.
    restored = app.cli_json("tab", "move", second["id"], str(fresh_slot + 1))["tabs"][0]
    assert restored["index"] == fresh_slot + 1
    after = app.cli_json("tab", "list")["tabs"]
    assert [t["id"] for t in after[fresh_slot - 1 : fresh_slot + 1]] == [fresh_tab["id"], second["id"]]

    # Out-of-range slots are a typed error, never a silent clamp.
    refused = app.cli("tab", "move", second["id"], str(len(after) + 1), check=False)
    assert refused.returncode == 1
    assert refused.stdout == ""  # safe-fail contract: stdout only on success


def test_tab_close_follows_the_running_program_signal(app):
    """`tab close` without --force succeeds iff libghostty reports no running
    program (needsConfirmQuit) — the exact signal the close guard reads.
    Which branch runs is environment-dependent BY DESIGN: where shell
    integration reaches the zmx session shell (dev machines) an idle pane
    reads false and closes freely; where it can't (CI's bash 3.2 login shell
    gets no integration through the zmx daemon) the signal is pessimistically
    always-true and even an idle tab demands --force."""
    tab = app.cli_json("tab", "new")["tabs"][0]
    pane = wait_for(lambda: app.panes(tab=tab["id"]), message="the new tab's pane")[0]
    wait_for(lambda: app.pane_text(pane=pane["id"]), timeout=60, message="an idle prompt")

    if app.pane_inspect(pane=pane["id"])["needsConfirmQuit"]:
        refused = app.cli("tab", "close", tab["id"], check=False)
        assert refused.returncode == 1
        assert "running program" in refused.stderr
        app.cli("tab", "close", tab["id"], "--force")
    else:
        app.cli("tab", "close", tab["id"])
    assert tab["id"] not in {t["id"] for t in app.cli_json("tab", "list")["tabs"]}


def test_busy_tab_close_refused_then_forced(app, fresh_tab, live_pane):
    """The typed `busy` error is API surface: headless callers get it instead
    of the UI's confirmation dialog, and `--force` is the override. Sync via
    an output marker (see test_terminal_io for why not needsConfirmQuit);
    the refusal itself holds in every environment — with shell integration
    ghostty knows a program is running, and without it the signal is
    pessimistically true anyway."""
    nonce = uuid.uuid4().hex[:12]
    app.pane_run(
        f'/bin/sh -c "printf started-%s {nonce}; echo; sleep 300"',
        pane=live_pane["id"],
    )
    wait_for(
        lambda: f"started-{nonce}" in (app.pane_text(pane=live_pane["id"], scrollback=True) or ""),
        timeout=60,
        message="the sleep to start",
    )

    refused = app.cli("tab", "close", fresh_tab["id"], check=False)
    assert refused.returncode == 1
    assert "running program" in refused.stderr
    assert refused.stdout == ""  # safe-fail contract: stdout only on success

    app.cli("tab", "close", fresh_tab["id"], "--force")
    assert fresh_tab["id"] not in {t["id"] for t in app.cli_json("tab", "list")["tabs"]}


def _app_log(app):
    try:
        with open(app.log_stream_path) as f:
            return f.read()
    except OSError:
        return ""


def _process_exited(app, pane_id):
    """processExited via pane inspect, None while the surface is mid-rebuild
    (inspect errors with no_surface during the destroy→respawn window)."""
    try:
        return app.pane_inspect(pane=pane_id).get("processExited")
    except Exception:
        return None


def test_dropped_remote_pane_reconnects_on_project_select(app):
    """A remote pane whose ssh client died is respawned by the reconnect
    sweep's `.projectSelected` trigger — the one trigger drivable headlessly
    (wake and app-activation need real system transitions; there is
    deliberately NO manual reconnect verb — automatic or nothing, #281).
    The host is unreachable by construction, so what's asserted is the
    automatic respawn attempt itself: ssh dies → overlay (processExited) →
    select away and back → the sweep logs a respawn and a fresh ssh dials
    (and dies again, same pane, same session). The full round trip against a
    reachable host lives in test_remote_reconnect.py (docker-gated)."""
    projects = app.cli_json("project", "list")["projects"]
    original = next(p for p in projects if p.get("active"))
    app.cli("project", "create", "e2e-badhost.invalid:/tmp", "--name", "deadremote", "--select")
    try:
        pane = wait_for(lambda: app.panes(), timeout=30, message="the remote pane")[0]
        wait_for(
            lambda: _process_exited(app, pane["id"]) is True,
            timeout=60,
            message="the ssh client's death (processExited)",
        )
        assert "reconnect(projectSelected): respawning" not in _app_log(app)

        app.cli("project", "select", original["name"])
        app.cli("project", "select", "deadremote")

        wait_for(
            lambda: "reconnect(projectSelected): respawning 1 dropped remote pane" in _app_log(app),
            timeout=30,
            message="the reconnect sweep's respawn log line",
        )
        # The respawned ssh dials the same unreachable host and dies again —
        # same pane identity, same session name, back on the overlay.
        wait_for(
            lambda: _process_exited(app, pane["id"]) is True,
            timeout=60,
            message="the respawned ssh client's death",
        )
        panes = {p["id"]: p for p in app.panes()}
        assert pane["id"] in panes
        assert panes[pane["id"]]["session"] == pane["session"]
    finally:
        app.cli("project", "select", original["name"], check=False)
