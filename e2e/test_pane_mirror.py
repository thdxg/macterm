"""Mirrored panes (#345): two panes attached to ONE zmx session.

`zmx attach` is an upsert and its daemon broadcasts pty output to every
attached client, so a mirror is a second live view of the same shell rather
than a copy of its text. These tests prove that against the real daemon —
output typed into one pane has to surface in the other's renderer cells, and
closing one must leave the session running for the other.

Everything targets `--pane`, never `--session`: mirrors share a session name
by construction, so a session selector is ambiguous for exactly these panes.

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
