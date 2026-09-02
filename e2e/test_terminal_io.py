"""Terminal I/O round-trips: CLI → socket → AppState → libghostty → pty →
shell → renderer cell state, read back out with `pane dump`.

Commands typed into panes must parse in ANY login shell — CI runners use zsh,
dev machines may run fish or nushell — so everything is `/bin/sh -c "…"` with
a single-quote-free, backslash-free script: the one form POSIX shells and
nushell tokenize identically (the same trick as the benchmark's workload
command and RemoteSpawn's wire format).
"""

import time
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


def test_ctrl_c_interrupts_foreground_program(app, live_pane):
    """`pane key` drives libghostty's key-encoding path (a real control byte,
    not pasted text). Interrupt delivery is proven with output markers, not a
    ghostty-side idle/running signal — needsConfirmQuit is only accurate
    where shell integration reaches the zmx session shell, and CI's bash 3.2
    login shell gets none, reading as perpetually busy. The protocol:
    `started` printing proves sleep is running when the SIGINT goes in;
    `after` executing while `finished` never prints proves the interrupt
    landed (an uninterrupted sleep would hold the shell for 300s, leaving
    the `after` line an unexecuted buffered keystroke, and a non-interactive
    sh aborts on a SIGINT'd child so `finished` can only print if the
    interrupt missed)."""
    pane_id = live_pane["id"]
    nonce = uuid.uuid4().hex[:12]

    def dump():
        return app.pane_text(pane=pane_id, scrollback=True) or ""

    app.pane_run(
        f'/bin/sh -c "printf started-%s {nonce}; echo; sleep 300; printf finished-%s {nonce}; echo"',
        pane=pane_id,
    )
    wait_for(lambda: f"started-{nonce}" in dump(), timeout=60, message="the sleep to start")

    app.cli("pane", "key", "ctrl+c", "--pane", pane_id)
    app.pane_run(f'/bin/sh -c "printf after-%s {nonce}; echo"', pane=pane_id)
    wait_for(
        lambda: f"after-{nonce}" in dump(),
        timeout=60,
        message="the shell to execute a command after ctrl+c",
    )
    assert f"finished-{nonce}" not in dump()


def test_printable_keys_reach_the_running_program(app, live_pane):
    """A bare printable chord must land as a keystroke. `pane key` sends a
    keycode + mods with no text, which libghostty encodes for control and
    named keys but not for a printable character — so `pane key a` used to
    exit 0 and deliver nothing at all.

    `cat -v` is the reader, and Return is what separates delivery from echo:
    the marker appears once from the pty's own echo of the typed bytes and a
    second time when cat writes the line back, so two occurrences prove the
    characters reached the program, not just the tty."""
    pane_id = live_pane["id"]
    nonce = uuid.uuid4().hex[:8]

    def dump():
        return app.pane_text(pane=pane_id, scrollback=True) or ""

    app.pane_run(
        f'/bin/sh -c "printf started-%s {nonce}; echo; cat -v"',
        pane=pane_id,
    )
    wait_for(lambda: f"started-{nonce}" in dump(), timeout=60, message="cat to start")

    # Letters and digits from the nonce, then the two chords whose character
    # comes from somewhere other than the token itself: space, and a shifted
    # symbol (US-ANSI shift+1 → "!").
    for chord in list(nonce) + ["space", "shift+1"]:
        app.cli("pane", "key", chord, "--pane", pane_id)
    typed = f"{nonce} !"
    wait_for(
        lambda: typed in dump(),
        timeout=30,
        message=f"the typed characters {typed!r} to echo",
    )

    app.cli("pane", "key", "return", "--pane", pane_id)
    wait_for(
        lambda: dump().count(typed) >= 2,
        timeout=30,
        message=f"cat to write {typed!r} back",
    )


def test_written_text_waits_on_the_prompt_until_return(app, live_pane):
    """`pane write` is `pane run` minus the trailing newline, and the only
    proof of that is behavioural: the text has to reach the prompt and then
    sit there. So this asserts both halves — the fragment echoes (it was
    delivered) while the marker it would print stays absent (it did not run),
    and only the following `pane key return` executes it.

    The marker is assembled by printf at runtime, so the typed line the dump
    also shows can never contain it; a match means the shell ran the command
    rather than echoing the keystrokes."""
    pane_id = live_pane["id"]
    nonce = uuid.uuid4().hex[:12]
    marker = f"w-{nonce}-ok"

    def dump():
        return app.pane_text(pane=pane_id, scrollback=True) or ""

    app.pane_write(f'/bin/sh -c "printf w-%s-ok {nonce}; echo"', pane=pane_id)
    # The nonce reaching the screen proves the paste landed; it appears only
    # as the prompt's echo of what was typed, never as command output.
    wait_for(lambda: nonce in dump(), timeout=60, message="the written text to echo")

    # Nothing may execute without a Return. Hold the negative across a few
    # polls rather than a single instant, so a command that merely started
    # slowly can't pass as one that never started.
    for _ in range(6):
        assert marker not in dump(), "pane write executed the text without a Return"
        time.sleep(0.5)

    app.cli("pane", "key", "return", "--pane", pane_id)
    wait_for(lambda: marker in dump(), timeout=30, message=f"marker {marker} after Return")
