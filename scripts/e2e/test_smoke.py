"""Boot-path smoke: launch → project open → live shell → readable terminal.

These tests only READ the initial project pane; mutation tests take
`fresh_tab` and work in their own tab.
"""

import subprocess

from _harness import wait_for


def test_status_reports_this_instance(app):
    status = app.cli_json("status")["status"]
    assert status["pid"] == app.pid
    assert status["version"]
    # BenchmarkControl.openProject names the harness-opened project.
    assert status["activeProject"] == "Benchmark"


def test_initial_pane_is_live_with_a_prompt(app):
    panes = wait_for(lambda: app.panes(), message="a pane in the initial project")
    assert len(panes) == 1
    pane = panes[0]
    # Session identity is the restart-stable address every other verb targets.
    assert pane["session"].startswith("macterm-")
    # A non-empty dump proves the whole stack: surface created, shell spawned,
    # prompt rendered into libghostty's cell state, read back over the socket.
    text = wait_for(
        lambda: app.pane_text(pane=pane["id"]),
        timeout=60,
        message="the initial pane's shell prompt",
    )
    assert text.strip()


def test_foreground_process_resolves(app):
    """The adaptive foreground poll resolves the idle pane's shell name —
    the signal tab titles and layout save build on. Generous timeout on
    purpose: a freshly spawned zmx session that misses the resolver's
    registration retry window waits for the 30s reconcile TTL, so the
    worst healthy case is ~30s after launch (the wait returns early when
    it's already resolved)."""
    pane = wait_for(lambda: app.panes(), message="a pane in the initial project")[0]
    process = wait_for(
        lambda: (app.panes() or [{}])[0].get("process"),
        timeout=90,
        message="the idle pane's foreground process name",
    )
    assert process  # login-shell name; environment-dependent (zsh on CI)
    assert pane["session"]  # unchanged by polling


def test_the_front_is_taken_back_from_another_app(app):
    """`_active_app`'s premise, proven on the runner it exists for: once
    another app holds the front — Finder, as it does after a test's own
    scripted instance is killed — the bench `activate` hook takes it back
    (the cooperative request would be refused). `open -a` is LaunchServices,
    so it needs no TCC grant, unlike System Events. The password monitor is
    the consumer: it watches the active app's key window only, and
    test_passwords.py sat behind Finder for both its timeouts on CI."""
    subprocess.run(["open", "-a", "Finder"], check=True)
    wait_for(lambda: not app.is_frontmost(), timeout=10, message="Finder to take the front")
    app.activate()
    assert app.is_frontmost()
