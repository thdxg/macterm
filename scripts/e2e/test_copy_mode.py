"""Copy mode: the Helix keys move the terminal's selection, driven end to end
through the pane's real surface.

The debug-only `pane copy-mode` verb turns the mode on and reads its state
and the selection text back, so no test reads the clipboard. The keys go
through `pane key`, which `sendKey` hands to the same copy-mode gate as a
real key press. Every motion resolves to a libghostty keybind action of fork
patch 0013 (`move_selection`, `select_line`...), so this also proves the
pinned GhosttyKit carries the patch.

The prompt can be more than one row (nushell draws two), so the test counts
rows from the pane dump instead of assuming where the cursor is: the marker
line's row and the last non-empty row, which the cursor sits on.
"""

import uuid

from _harness import wait_for


def _state(app, pane_id, action=None):
    args = ["pane", "copy-mode"]
    if action:
        args.append(action)
    state = app.cli_json(*args, "--pane", pane_id)["copyMode"]
    state.setdefault("selection", None)
    return state


def _key(app, pane_id, chord):
    app.cli("pane", "key", chord, "--pane", pane_id)


def _rows(app, pane_id):
    text = app.pane_text(pane=pane_id) or ""
    return text.split("\n")


def test_copy_mode_selects_lines_with_helix_keys(app, live_pane):
    pane_id = live_pane["id"]
    nonce = uuid.uuid4().hex[:8]
    alpha, bravo, charlie = (f"{name}-{nonce}" for name in ("alpha", "bravo", "charlie"))
    app.pane_run(
        f'/bin/sh -c "printf {alpha}; echo; printf {bravo}; echo; printf {charlie}; echo"',
        pane=pane_id,
    )
    wait_for(lambda: charlie in (app.pane_text(pane=pane_id) or ""), message="the marker lines")

    rows = _rows(app, pane_id)
    bravo_row = next(i for i, row in enumerate(rows) if row.startswith(bravo))
    cursor_row = max(i for i, row in enumerate(rows) if row.strip())
    assert cursor_row > bravo_row

    state = _state(app, pane_id, "enter")
    assert state["active"] and not state["selectMode"]

    # Up to the bravo line, then the whole line.
    for _ in range(cursor_row - bravo_row):
        _key(app, pane_id, "k")
    _key(app, pane_id, "x")
    state = _state(app, pane_id)
    assert state["active"]
    assert state["selection"].strip() == bravo

    # `x` again adds the next line.
    _key(app, pane_id, "x")
    selection = _state(app, pane_id)["selection"]
    assert bravo in selection and charlie in selection
    assert alpha not in selection

    # `y` copies and leaves the mode; the selection is gone with it.
    _key(app, pane_id, "y")
    state = _state(app, pane_id)
    assert not state["active"]
    assert state["selection"] is None

    # Typing reaches the shell again.
    marker = f"typed-{nonce}"
    app.pane_run(f'/bin/sh -c "printf {marker}; echo"', pane=pane_id)
    wait_for(lambda: marker in (app.pane_text(pane=pane_id) or ""), message="the shell to type again")


def test_a_repeated_w_moves_word_by_word(app, live_pane):
    pane_id = live_pane["id"]
    nonce = uuid.uuid4().hex[:8]
    one, two, three = (f"{name}-{nonce}" for name in ("one", "two", "three"))
    app.pane_run(f'/bin/sh -c "echo {one} {two} {three}"', pane=pane_id)
    # The typed command holds the same words, so look for the output row.
    line = f"{one} {two} {three}"
    wait_for(lambda: any(row.startswith(line) for row in _rows(app, pane_id)), message="the word line")

    rows = _rows(app, pane_id)
    line_row = next(i for i, row in enumerate(rows) if row.startswith(line))
    cursor_row = max(i for i, row in enumerate(rows) if row.strip())

    _state(app, pane_id, "enter")
    for _ in range(cursor_row - line_row):
        _key(app, pane_id, "k")
    _key(app, pane_id, "g")
    _key(app, pane_id, "h")

    # The first `w` selects the first word and the blank after it.
    _key(app, pane_id, "w")
    assert _state(app, pane_id)["selection"].strip() == one

    # The second `w` moves on to the next word. It stopped on the blank
    # before fork thdxg/ghostty#30.
    _key(app, pane_id, "w")
    assert _state(app, pane_id)["selection"].strip() == two

    _state(app, pane_id, "exit")


def test_escape_leaves_select_mode_before_copy_mode(app, live_pane):
    pane_id = live_pane["id"]
    state = _state(app, pane_id, "enter")
    assert state["active"]

    _key(app, pane_id, "v")
    assert _state(app, pane_id)["selectMode"]

    _key(app, pane_id, "escape")
    state = _state(app, pane_id)
    assert state["active"] and not state["selectMode"]

    _key(app, pane_id, "escape")
    assert not _state(app, pane_id)["active"]


def test_a_key_in_copy_mode_does_not_reach_the_shell(app, live_pane):
    pane_id = live_pane["id"]
    nonce = uuid.uuid4().hex[:8]
    _state(app, pane_id, "enter")
    # `z` is not a copy-mode key; it must be swallowed, not typed.
    for ch in "zz":
        _key(app, pane_id, ch)
    _state(app, pane_id, "exit")
    app.pane_run(f'/bin/sh -c "printf after-{nonce}; echo"', pane=pane_id)
    wait_for(lambda: f"after-{nonce}" in (app.pane_text(pane=pane_id) or ""), message="the shell prompt")
    assert "zz" not in (app.pane_text(pane=pane_id) or "")


def test_vim_keys_select_lines_with_visual_line_mode(app, live_pane):
    """The Vim keymap, named on enter so the setting stays as it is: `V`
    takes the line, `k` grows the selection up a line (the direction is
    kept, which `select_line_bounds` of fork patch 0015 gives), `y` copies
    and leaves."""
    pane_id = live_pane["id"]
    nonce = uuid.uuid4().hex[:8]
    alpha, bravo, charlie = (f"{name}-{nonce}" for name in ("alpha", "bravo", "charlie"))
    app.pane_run(
        f'/bin/sh -c "printf {alpha}; echo; printf {bravo}; echo; printf {charlie}; echo"',
        pane=pane_id,
    )
    wait_for(lambda: charlie in (app.pane_text(pane=pane_id) or ""), message="the marker lines")

    rows = _rows(app, pane_id)
    charlie_row = next(i for i, row in enumerate(rows) if row.startswith(charlie))
    cursor_row = max(i for i, row in enumerate(rows) if row.strip())

    state = app.cli_json("pane", "copy-mode", "enter", "--keymap", "vim", "--pane", pane_id)["copyMode"]
    assert state["active"]

    for _ in range(cursor_row - charlie_row):
        _key(app, pane_id, "k")
    _key(app, pane_id, "shift+v")
    assert _state(app, pane_id)["selection"].strip() == charlie

    # Up a line in visual line mode: both lines, whole.
    _key(app, pane_id, "k")
    selection = _state(app, pane_id)["selection"]
    assert bravo in selection and charlie in selection
    assert alpha not in selection

    # And one more: the head still moves up.
    _key(app, pane_id, "k")
    assert alpha in _state(app, pane_id)["selection"]

    _key(app, pane_id, "y")
    state = _state(app, pane_id)
    assert not state["active"]
    assert state["selection"] is None
