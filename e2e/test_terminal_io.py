"""Terminal I/O round-trips: CLI → socket → AppState → libghostty → pty →
shell → renderer cell state, read back out with `pane dump`.

Commands typed into panes must parse in ANY login shell — CI runners use zsh,
dev machines may run fish or nushell — so everything is `/bin/sh -c "…"` with
a single-quote-free, backslash-free script: the one form POSIX shells and
nushell tokenize identically (the same trick as the benchmark's workload
command and RemoteSpawn's wire format).
"""

import uuid

from _harness import wait_for


def test_typed_command_output_appears_in_dump(app, live_pane):
    nonce = uuid.uuid4().hex[:12]
    marker = f"e2e-{nonce}-ok"
    # printf assembles the marker at runtime, so the typed command line (which
    # the dump also shows, echoed at the prompt) never contains it — a match
    # proves the shell *executed* the command, not that the keystrokes echoed.
    app.pane_run(f'/bin/sh -c "printf e2e-%s-ok {nonce}; echo"', pane=live_pane["id"])
    wait_for(
        lambda: marker in (app.pane_text(pane=live_pane["id"], scrollback=True) or ""),
        timeout=60,
        message=f"marker {marker} in the pane's dump",
    )


def test_ctrl_c_interrupts_foreground_program(app, live_pane, running_program):
    """`pane key` drives libghostty's key-encoding path (a real control byte,
    not pasted text); the running-program signal flipping on and back off
    proves the SIGINT actually reached the foreground process group."""
    wait_for(lambda: not running_program(), timeout=60, message="an idle pane")

    app.pane_run('/bin/sh -c "sleep 300"', pane=live_pane["id"])
    wait_for(
        running_program,
        timeout=60,
        message="the sleep to register as a running program",
    )

    app.cli("pane", "key", "ctrl+c", "--pane", live_pane["id"])
    wait_for(
        lambda: not running_program(),
        timeout=60,
        message="the shell to return to its prompt after ctrl+c",
    )
