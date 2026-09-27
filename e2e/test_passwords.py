"""Password prompts: detection, the save offer, and autofill, driven end to end
through the pane's real tty.

A `/bin/sh` script plays the program asking for a password: `stty -echo` +
`read` is exactly the mode every password reader uses (canonical, echo off),
and it is what `ProcessInspector.terminalIsReadingPassword` looks for on the
zmx session's tty. The typed password reaches the monitor through the same
`sendText` path the CLI's `pane run` uses, and the bubble is answered through
the debug-only `pane password` verb — the buttons as a verb, since nobody is
at the keyboard. Under the harness (`MACTERM_BENCHMARK_DATA_DIR`) passwords
live in memory and Touch ID is skipped (debug builds only), so the suite
never touches a keychain.

Every claim is proven by output the script prints only for the right
password, assembled at runtime so the echoed command line can't match it.
"""

import uuid
from pathlib import Path

from _harness import wait_for


def _login_script(app, nonce):
    """A fake login: prompts, accepts `pw-<nonce>`, prints `welcome-<nonce>` for
    it and `denied` (a failure marker) for anything else, then prompts again
    like ssh would. Lives in the harness home, which is thrown away."""
    path = Path(app.home) / f"login-{nonce}.sh"
    path.write_text(
        "#!/bin/sh\n"
        "attempt=0\n"
        "while [ $attempt -lt 3 ]; do\n"
        "  attempt=$((attempt + 1))\n"
        "  stty -echo\n"
        "  printf 'demo@e2e password: '\n"
        "  read p\n"
        "  stty echo\n"
        "  echo\n"
        f'  if [ "$p" = "pw-{nonce}" ]; then\n'
        f"    printf welcome-%s {nonce}; echo\n"
        "    sleep 300\n"
        "    exit 0\n"
        "  fi\n"
        "  echo 'Permission denied, please try again.'\n"
        "done\n"
        "exit 255\n"
    )
    path.chmod(0o755)
    return str(path)


def _normalized(state):
    """The wire encoding omits nil fields; absent means none."""
    for key in ("prompt", "command", "bubble"):
        state.setdefault(key, None)
    return state


def _state(app, pane_id):
    return _normalized(app.cli_json("pane", "password", "--pane", pane_id)["password"])


def _answer(app, pane_id, reply):
    return _normalized(app.cli_json("pane", "password", "--pane", pane_id, "--answer", reply)["password"])


def _wait_for_prompt(app, pane_id):
    """The monitor has confirmed a password prompt in the pane."""
    return wait_for(
        lambda: (s := _state(app, pane_id))["phase"] == "prompting" and s,
        timeout=30,
        message="the password prompt to be detected",
    )


def test_typed_password_is_offered_saved_and_autofilled(app, live_pane):
    pane_id = live_pane["id"]
    nonce = uuid.uuid4().hex[:10]
    script = _login_script(app, nonce)

    def dump():
        return app.pane_text(pane=pane_id, scrollback=True) or ""

    # 1. A wrong password: judged failed, nothing offered, prompt comes back.
    app.pane_run(f"/bin/sh {script}", pane=pane_id)
    state = _wait_for_prompt(app, pane_id)
    assert state["prompt"] == "demo@e2e password:"
    # Filed under the script, not the bare `sh` that runs it — a shell
    # executing a script is a command, so two scripts with the same prompt
    # keep separate passwords.
    assert state["command"].endswith(script)
    assert state["saved"] is False
    assert state["bubble"] is None, "nothing is saved yet, so no bubble"

    app.pane_run("not-the-password", pane=pane_id)
    wait_for(lambda: "Permission denied" in dump(), timeout=30, message="the rejection")
    # The rejection re-prompts; the monitor must see that as a fresh prompt
    # with still no offer on the table.
    state = _wait_for_prompt(app, pane_id)
    assert state["bubble"] is None

    # 2. The right password: judged by the welcome line, then offered.
    app.pane_run(f"pw-{nonce}", pane=pane_id)
    wait_for(lambda: f"welcome-{nonce}" in dump(), timeout=30, message="the welcome line")
    state = wait_for(
        lambda: (s := _state(app, pane_id))["bubble"] == "save" and s,
        timeout=30,
        message="the save offer",
    )
    assert state["phase"] == "idle"

    # 3. Save it, then the next run of the same command offers Autofill.
    _answer(app, pane_id, "accept")
    assert _state(app, pane_id)["bubble"] is None
    app.cli("pane", "key", "ctrl+c", "--pane", pane_id)
    app.pane_run(f"/bin/sh {script}", pane=pane_id)
    state = _wait_for_prompt(app, pane_id)
    assert state["saved"] is True
    assert state["bubble"] == "autofill"

    # 4. Autofill types the saved password: the script greets a second time.
    _answer(app, pane_id, "autofill")
    wait_for(
        lambda: dump().count(f"welcome-{nonce}") >= 2,
        timeout=30,
        message="the welcome line from the autofilled password",
    )
    # An autofilled password that worked is not offered for saving again.
    wait_for(lambda: _state(app, pane_id)["phase"] == "idle", timeout=30, message="the judge to settle")
    assert _state(app, pane_id)["bubble"] is None


def test_dismissed_offer_and_wrong_password_save_nothing(app, live_pane):
    pane_id = live_pane["id"]
    nonce = uuid.uuid4().hex[:10]
    script = _login_script(app, nonce)

    def dump():
        return app.pane_text(pane=pane_id, scrollback=True) or ""

    app.pane_run(f"/bin/sh {script}", pane=pane_id)
    _wait_for_prompt(app, pane_id)
    app.pane_run(f"pw-{nonce}", pane=pane_id)
    wait_for(lambda: _state(app, pane_id)["bubble"] == "save", timeout=30, message="the save offer")

    # Cancel: the offer is gone and the next prompt has nothing saved.
    _answer(app, pane_id, "dismiss")
    assert _state(app, pane_id)["bubble"] is None
    app.cli("pane", "key", "ctrl+c", "--pane", pane_id)
    app.pane_run(f"/bin/sh {script}", pane=pane_id)
    state = _wait_for_prompt(app, pane_id)
    assert state["saved"] is False
    assert state["bubble"] is None

    # ⌃C at the prompt: the read is abandoned and the phase returns to idle
    # with no offer, even though characters were typed. The one welcome on
    # screen is the earlier login's; nothing was typed for the script since.
    greetings = dump().count(f"welcome-{nonce}")
    app.pane_run("partial", pane=pane_id, submit=False)
    app.cli("pane", "key", "ctrl+c", "--pane", pane_id)
    wait_for(lambda: _state(app, pane_id)["phase"] == "idle", timeout=30, message="the prompt to end")
    assert _state(app, pane_id)["bubble"] is None
    assert dump().count(f"welcome-{nonce}") == greetings
