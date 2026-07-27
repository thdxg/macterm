"""End-to-end suite fixtures.

The suite drives a real, GUI Macterm.app: launched hermetically (throwaway
$HOME, isolated app data + zmx namespace, Darwin-notification control — see
scripts/_harness.py, shared with the benchmark) and asserted against through
the bundled `macterm` CLI, whose `pane dump`/`pane inspect`/`pane list` read
libghostty's own live state. `mise run e2e` builds the Debug app and runs
this; `pytest e2e --app <path>` targets an already-built app.

Isolation model: launching the app costs ~15-30s on a shared runner, so ONE
instance serves the whole session. Tests own their blast radius instead —
take the `fresh_tab` fixture for a tab of your own; the autouse janitor
closes any tab a test leaves behind. Tests must not mutate the initial
project pane (smoke tests read it).

Every wait is a deadline poll (scripts/_harness.py `wait_for`), never a fixed
sleep — the suite runs on loaded shared runners where any "long enough" sleep
eventually isn't.
"""

import os
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from _harness import HarnessError, MactermHarness, wait_for  # noqa: E402

DIAG_ROOT = REPO / "build" / "e2e" / "diagnostics"


def pytest_addoption(parser):
    parser.addoption(
        "--app",
        default=str(REPO / "build" / "DerivedData" / "Build" / "Products" / "Debug" / "Macterm.app"),
        help="Path to the built Macterm.app under test (default: the Debug build)",
    )


@pytest.fixture(scope="session")
def app(request):
    """The launched app instance, shared by the whole session."""
    app_path = request.config.getoption("--app")
    if not os.path.exists(app_path):
        pytest.exit(f"no app at {app_path} — build it first (`mise run e2e` builds and runs)", returncode=2)
    harness = MactermHarness(app_path, home_prefix="macterm-e2e-home-")
    try:
        try:
            harness.launch()
            harness.open_project()
            harness.wait_for_socket()
        except HarnessError:
            harness.dump_diagnostics(DIAG_ROOT / "session-launch")
            raise
        yield harness
    finally:
        harness.cleanup()


# Expose each phase's report on the item so fixtures can ask "did the test
# that just ran fail?" — the standard pytest pattern for teardown forensics.
@pytest.hookimpl(wrapper=True)
def pytest_runtest_makereport(item, call):
    report = yield
    setattr(item, "rep_" + report.when, report)
    return report


@pytest.fixture(autouse=True)
def _tab_janitor(app):
    """Close (force) any tab the test created, so tests can't leak state into
    each other. Snapshot-based: pre-existing tabs are never touched."""
    before = {tab["id"] for tab in app.cli_json("tab", "list")["tabs"]}
    yield
    for tab in app.cli_json("tab", "list")["tabs"]:
        if tab["id"] not in before:
            app.cli("tab", "close", tab["id"], "--force", check=False)


@pytest.fixture(autouse=True)
def _diagnostics_on_failure(request, app, _tab_janitor):
    """On failure, capture a screenshot, the app's unified log, and every
    pane's text into build/e2e/diagnostics/<test>/ (uploaded as a CI
    artifact). Depends on the janitor so this teardown runs FIRST — while the
    failed test's tabs still exist."""
    yield
    report = getattr(request.node, "rep_call", None)
    if report is not None and report.failed:
        diag_dir = DIAG_ROOT / request.node.name
        app.dump_diagnostics(diag_dir)
        app.dump_panes(diag_dir)


@pytest.fixture
def fresh_tab(app):
    """A new tab for the test to own. `tab new` makes it active with keyboard
    focus on its single pane, so untargeted pane verbs act on it."""
    return app.cli_json("tab", "new")["tabs"][0]


@pytest.fixture
def live_pane(app, fresh_tab):
    """The fresh tab's pane, waited until its surface is live and the shell
    has drawn a prompt — the precondition for `pane run`/`pane key`/dump."""
    pane = wait_for(lambda: app.panes(tab=fresh_tab["id"]), message="the fresh tab's pane")[0]
    wait_for(
        lambda: app.pane_text(pane=pane["id"]),
        timeout=60,
        message="the fresh tab's shell prompt",
    )
    return pane


@pytest.fixture
def running_program(app, live_pane):
    """Callable reading libghostty's running-program signal for the fresh
    tab's pane (`pane inspect` needsConfirmQuit — see MactermHarness
    .pane_inspect for why this, and not the foreground-name poll, is the
    sync point for 'a program is running')."""

    def read():
        return app.pane_inspect(pane=live_pane["id"])["needsConfirmQuit"]

    return read
