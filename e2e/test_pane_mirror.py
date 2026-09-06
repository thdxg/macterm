"""Mirrored panes (#345): two panes attached to ONE zmx session.

`zmx attach` is an upsert and its daemon broadcasts pty output to every
attached client, so a mirror is a second live view of the same shell rather
than a copy of its text. These tests prove that against the real daemon —
output typed into one pane has to surface in the other's renderer cells, and
closing one must leave the session running for the other.

These target `--pane` throughout: mirrors share a session name by
construction, so a session selector is ambiguous for exactly these panes. The
one exception is the test that pins how that ambiguity resolves.

Commands typed into panes must parse in ANY login shell (CI runs bash 3.2, dev
machines may run nushell), hence the `/bin/sh -c "…"` single-quote-free form
used across this suite.
"""

import uuid

from _harness import wait_for


def test_mirror_shares_the_sources_session(app, fresh_tab, live_pane):
    """A split gets its own session; a mirror deliberately does not."""
    app.cli("pane", "mirror", "--direction", "right", "--pane", live_pane["id"])
    panes = app.panes(tab=fresh_tab["id"])
    assert len(panes) == 2
    assert {pane["session"] for pane in panes} == {live_pane["session"]}
    # Distinct panes all the same — each needs its own surface, because one
    # NSView cannot live in two view hierarchies.
    assert len({pane["id"] for pane in panes}) == 2


def test_mirror_does_not_take_focus(app, fresh_tab, live_pane):
    """Unlike `pane split`. A mirror shows work the user is already looking
    at, so moving them off the pane they are using would be wrong."""
    app.cli("pane", "mirror", "--direction", "right", "--pane", live_pane["id"])
    focused = [pane["id"] for pane in app.panes(tab=fresh_tab["id"]) if pane["focused"]]
    assert focused == [live_pane["id"]]


def test_output_reaches_both_mirrors(app, fresh_tab, live_pane):
    """The point of the whole feature: one shell, two live views.

    The marker is assembled at runtime by printf, so the typed command line
    itself never contains it — a match proves the daemon BROADCAST executed
    output to the mirror, not that keystrokes echoed into both surfaces.
    """
    app.cli("pane", "mirror", "--direction", "right", "--pane", live_pane["id"])
    panes = app.panes(tab=fresh_tab["id"])
    mirror = next(pane for pane in panes if pane["id"] != live_pane["id"])
    wait_for(
        lambda: app.pane_text(pane=mirror["id"]),
        timeout=60,
        message="the mirror's surface to come up",
    )

    nonce = uuid.uuid4().hex[:12]
    marker = f"mirror-{nonce}-ok"
    app.pane_run(f'/bin/sh -c "printf mirror-%s-ok {nonce}; echo"', pane=live_pane["id"])

    for label, pane_id in (("source", live_pane["id"]), ("mirror", mirror["id"])):
        wait_for(
            lambda pane_id=pane_id: marker in (app.pane_text(pane=pane_id, scrollback=True) or ""),
            timeout=60,
            message=f"marker {marker} in the {label} pane's dump",
        )


def test_the_source_keeps_leadership_when_mirrored(app, fresh_tab, live_pane):
    """zmx sets a leader only when there is none, so a second client attaching
    leaves the pty size where it was. `pane list` must say the same."""
    app.cli("pane", "mirror", "--direction", "right", "--pane", live_pane["id"])
    panes = app.panes(tab=fresh_tab["id"])
    by_id = {pane["id"]: pane for pane in panes}
    mirror_id = next(pid for pid in by_id if pid != live_pane["id"])

    assert all(pane["mirror"] for pane in panes)
    assert by_id[live_pane["id"]]["leader"] is True
    assert by_id[mirror_id]["leader"] is False


def test_focusing_a_mirror_hands_it_leadership(app, fresh_tab, live_pane):
    """Leadership follows focus, and follows it back — it does not latch."""
    app.cli("pane", "mirror", "--direction", "right", "--pane", live_pane["id"])
    panes = app.panes(tab=fresh_tab["id"])
    mirror_id = next(p["id"] for p in panes if p["id"] != live_pane["id"])

    for target in (mirror_id, live_pane["id"], mirror_id):
        app.cli("pane", "focus", "--pane", target)
        leaders = [p["id"] for p in app.panes(tab=fresh_tab["id"]) if p["leader"]]
        assert leaders == [target]


def test_session_list_reports_every_bound_pane(app, fresh_tab, live_pane):
    """A mirrored session used to collapse to one arbitrary pane id, last
    writer winning in Dictionary order. Both must show, leader first."""
    app.cli("pane", "mirror", "--direction", "right", "--pane", live_pane["id"])
    panes = app.panes(tab=fresh_tab["id"])
    mirror_id = next(p["id"] for p in panes if p["id"] != live_pane["id"])

    sessions = app.cli_json("session", "list")["sessions"]
    entry = next(s for s in sessions if s["name"] == live_pane["session"])
    assert set(entry["paneIDs"]) == {live_pane["id"], mirror_id}
    # `paneID` stays the single-value view for older clients, and reports the
    # leader rather than whichever pane happened to be visited first.
    assert entry["paneID"] == live_pane["id"]
    assert entry["paneIDs"][0] == live_pane["id"]


def test_session_target_resolves_to_the_leader(app, fresh_tab, live_pane):
    """Mirrors share a session name, so `--session` is ambiguous by
    construction. It resolves to the leader — the pane driving the size, and
    the only defensible answer for a bare $MACTERM_SESSION self-target."""
    app.cli("pane", "mirror", "--direction", "right", "--pane", live_pane["id"])
    panes = app.panes(tab=fresh_tab["id"])
    mirror_id = next(p["id"] for p in panes if p["id"] != live_pane["id"])

    assert app.pane_inspect(session=live_pane["session"])["id"] == live_pane["id"]
    app.cli("pane", "focus", "--pane", mirror_id)
    assert app.pane_inspect(session=live_pane["session"])["id"] == mirror_id


def test_closing_a_mirror_leaves_the_session_running(app, fresh_tab, live_pane):
    """The refcount, against a real daemon rather than a stubbed ZmxClient.

    Closing one view of a session must not kill the shell the other view is
    still showing — proven by the surviving pane continuing to execute after
    the close, which a killed session could not do.
    """
    app.cli("pane", "mirror", "--direction", "right", "--pane", live_pane["id"])
    panes = app.panes(tab=fresh_tab["id"])
    mirror = next(pane for pane in panes if pane["id"] != live_pane["id"])
    wait_for(
        lambda: app.pane_text(pane=mirror["id"]),
        timeout=60,
        message="the mirror's surface to come up",
    )

    app.cli("pane", "close", "--pane", mirror["id"])
    remaining = wait_for(
        lambda: (lambda p: p if len(p) == 1 else None)(app.panes(tab=fresh_tab["id"])),
        message="the mirror to leave the tree",
    )
    assert remaining[0]["id"] == live_pane["id"]
    assert remaining[0]["session"] == live_pane["session"]

    # The session is still alive: it can still run a command.
    nonce = uuid.uuid4().hex[:12]
    marker = f"survived-{nonce}-ok"
    app.pane_run(f'/bin/sh -c "printf survived-%s-ok {nonce}; echo"', pane=live_pane["id"])
    wait_for(
        lambda: marker in (app.pane_text(pane=live_pane["id"], scrollback=True) or ""),
        timeout=60,
        message=f"marker {marker} after closing the mirror",
    )
