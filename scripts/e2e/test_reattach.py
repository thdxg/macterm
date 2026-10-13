"""A relaunch reattaches each pane to its zmx session, and the replayed
scrollback keeps its shape: a line wider than the pane is still one line,
and the rows right above the screen are still there.

Both broke in the reattach snapshot. The attaching client reported
libghostty's placeholder grid (47x13) before its real size, and zmx laid
the scrollback out for that grid, one hard line per row. Then the clear
between the scrollback and the visible screen erased the last screenful of
scrollback rows in place. The fork's zmx replays the scrollback as logical
lines and scrolls it out before the clear; the fork's libghostty opens the
pty at the view's real size.
"""

import json
import uuid

from _harness import MactermHarness, wait_for


def _text(harness, session):
    """The pane's text with its scrollback, or None while its surface isn't
    live yet. `pane dump` joins a soft-wrapped line back into one line, so a
    line that comes back split was hard-wrapped."""
    result = harness.cli("pane", "dump", "--session", session, "--scrollback", "--json", check=False)
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)["dump"]["text"]


def test_reattached_scrollback_keeps_long_lines_and_the_rows_above_the_screen(request):
    """Its own instance, since the shared one must not be restarted under
    the other tests."""
    harness = MactermHarness(request.config.getoption("--app"), home_prefix="macterm-e2e-reattach-home-")
    try:
        harness.launch()
        harness.open_project()
        harness.wait_for_socket()
        tab = harness.cli_json("tab", "new")["tabs"][0]
        pane = wait_for(lambda: harness.panes(tab=tab["id"]), message="the tab's pane")[0]
        session = pane["session"]
        wait_for(lambda: _text(harness, session), timeout=60, message="the shell prompt")
        rows = harness.pane_inspect(session=session)["rows"]

        nonce = uuid.uuid4().hex[:12]
        wide = f"wide-{nonce}-" + "0" * 400
        above = f"above-{nonce}"
        # A line wider than any pane, a marker, then a screenful of filler so
        # the marker ends up a few rows above the visible screen: inside the
        # band the old snapshot erased, whatever grid the client attached
        # with. The markers are assembled here, so the typed command line
        # never contains them (printf builds the wide line from a width).
        harness.pane_run(
            f'/bin/sh -c "printf wide-%s-%0400d {nonce} 0; echo; printf above-%s {nonce}; echo; seq 1 {rows + 3}"',
            session=session,
        )
        wait_for(
            lambda: f"\n{rows + 3}\n" in (_text(harness, session) or ""),
            timeout=60,
            message="the filler to finish",
        )
        before = _text(harness, session)
        assert wide in before
        assert above in before

        harness.kill()
        harness.launch()
        harness.wait_for_socket()

        def replayed():
            text = _text(harness, session) or ""
            return text if f"\n{rows + 3}\n" in text else None

        after = wait_for(replayed, timeout=60, message="the reattached session to replay its scrollback")
        # One line, not a stack of rows cut at the width the client reported
        # before it had its real size.
        assert wide in after, f"the wide line came back split:\n{after}"
        # The rows right above the screen survived the clear between the
        # scrollback and the visible screen.
        assert above in after, f"the rows above the screen were erased:\n{after}"
    finally:
        harness.cleanup()
