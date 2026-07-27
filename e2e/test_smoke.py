"""Boot-path smoke: launch → project open → live shell → readable terminal.

These tests only READ the initial project pane; mutation tests take
`fresh_tab` and work in their own tab.
"""

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
