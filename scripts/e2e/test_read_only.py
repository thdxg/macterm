"""Read-only panes: `pane run` and `pane key` refuse a read-only pane with
`read_only`, and `pane inspect` reports the state.

libghostty drops every input to a read-only surface and tells nobody, so
without the refusal both verbs say ok for text that the program never got.
The suite has no keyboard for the Read-Only Mode command, so the debug-only
`pane read-only` verb sends its `toggle_readonly` binding action instead. libghostty reports the change asynchronously, so the test polls
`pane inspect`.
"""

import uuid

from _harness import sh, wait_for


def _read_only(app, pane_id):
    return app.pane_inspect(pane=pane_id).get("readOnly") is True


def _toggle(app, pane_id, want):
    app.cli("pane", "read-only", "--pane", pane_id)
    wait_for(
        lambda: _read_only(app, pane_id) is want,
        message=f"the pane to be {'read-only' if want else 'writable'}",
    )


def _run(app, pane_id, text):
    """`pane run` without the harness's raise, to read the refusal."""
    return sh([app.cli_path, "pane", "run", "--socket", app.socket, "--pane", pane_id, "--", text], timeout=60)


def test_pane_run_and_key_refuse_a_read_only_pane(app, live_pane):
    pane_id = live_pane["id"]
    nonce = uuid.uuid4().hex[:8]
    assert not _read_only(app, pane_id)

    _toggle(app, pane_id, True)
    try:
        result = _run(app, pane_id, f"printf blocked-%s {nonce}")
        assert result.returncode == 1, result.stderr
        assert "read-only" in result.stderr

        # A key that would go to the program is refused too.
        key = app.cli("pane", "key", "x", "--pane", pane_id, check=False)
        assert key.returncode == 1, key.stderr
        assert "read-only" in key.stderr

        # A keybind is not input: libghostty still runs it on a read-only
        # surface (`super+a=select_all` is a ghostty default).
        app.cli("pane", "key", "cmd+a", "--pane", pane_id)
    finally:
        _toggle(app, pane_id, False)

    # Nothing of the refused text reached the shell, and the pane types again.
    app.pane_run(f"printf typed-%s {nonce}", pane=pane_id)
    wait_for(lambda: f"typed-{nonce}" in (app.pane_text(pane=pane_id) or ""), message="the marker")
    assert f"blocked-%s {nonce}" not in (app.pane_text(pane=pane_id, scrollback=True) or "")
