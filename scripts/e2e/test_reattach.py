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

The pane is a desktop widget: its session persists across a relaunch like
any pane's, and it needs no window. A second instance's window is not key
under the shared instance, and a tab that is never shown has no surface.
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


def _widgets(harness):
    return harness.cli_json("widget", "list").get("widgets") or []


def test_reattached_scrollback_keeps_long_lines_and_the_rows_above_the_screen(request):
    """Its own instance, since the shared one must not be restarted under
    the other tests."""
    harness = MactermHarness(request.config.getoption("--app"), home_prefix="macterm-e2e-reattach-home-")
    try:
        harness.launch()
        harness.wait_for_socket()
        created = harness.cli_json("widget", "new", "--size", "2x2")["widgets"][0]
        session = created["session"]
        wait_for(lambda: _text(harness, session), timeout=60, message="the widget's shell prompt")
        rows = harness.pane_inspect(session=session)["rows"]

        nonce = uuid.uuid4().hex[:12]
        wide = f"wide-{nonce}-" + "0" * 400
        above = f"above-{nonce}"
        screen = f"screen-{nonce}-" + "0" * 200
        filler = rows + 1
        # A line wider than any pane, a marker, then one screen of filler plus
        # one row, so the marker and the whole line end up in the scrollback a
        # row or two above the visible screen: inside the band the old
        # snapshot erased. Then a second wide line that stays on the visible
        # screen, which the snapshot replays with its own layout. The markers
        # are assembled here, so the typed command line never contains them
        # (printf builds the wide lines from a width).
        harness.pane_run(
            f'/bin/sh -c "printf wide-%s-%0400d {nonce} 0; echo; printf above-%s {nonce}; echo;'
            f' seq -f filler-%g 1 {filler}; printf screen-%s-%0200d {nonce} 0; echo"',
            session=session,
        )
        wait_for(lambda: screen in (_text(harness, session) or ""), timeout=60, message="the output to finish")
        before = _text(harness, session)
        assert wide in before
        assert above in before

        harness.kill()
        harness.launch()
        harness.wait_for_socket()
        wait_for(lambda: _widgets(harness), timeout=30, message="the widget to be restored")

        def replayed():
            text = _text(harness, session) or ""
            return text if f"filler-{filler}" in text else None

        after = wait_for(replayed, timeout=60, message="the reattached session to replay its scrollback")
        # One line, not a stack of rows cut at the width the client reported
        # before it had its real size.
        assert wide in after, f"the wide line came back split:\n{after}"
        # The rows right above the screen survived the clear between the
        # scrollback and the visible screen.
        assert above in after, f"the rows above the screen were erased:\n{after}"
        # The visible screen is replayed as logical lines too.
        assert screen in after, f"the wide line on the screen came back split:\n{after}"
    finally:
        harness.cleanup()
