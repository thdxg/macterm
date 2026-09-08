"""Multiple terminal windows (#345).

Macterm was deliberately single-window. These drive the real app to prove the
parts that only exist once there is more than one: each window renders its own
project, each carries its own title (which is what puts it in the macOS Window
menu), and closing one leaves the others alone.

The window verbs exist partly so this suite can drive them — a keybinding and a
menu item are not reachable from here without an Accessibility grant.
"""

import time
import uuid

from _harness import wait_for


def _windows(app):
    return app.cli_json("window", "list")["windows"]


def _close_extra_windows(app, target):
    """Return the app to `target` windows, whatever the test left behind.

    The suite shares ONE app instance, so a window leaked here fails the next
    test rather than this one — and the launch test's "exactly one" assertion
    is the first casualty.
    """
    for _ in range(6):
        if len(_windows(app)) <= target:
            return
        app.cli("window", "close")
        time.sleep(1)


def _project_of(window):
    """`project` is absent, not null, when a window has none — the encoder
    omits nil rather than writing it."""
    return window.get("project")


def test_launch_opens_exactly_one_window(app):
    """A spare window at launch is the failure this guards.

    Giving the WindowGroup an explicit id (so `openWindow(id:)` could address
    it) made SwiftUI open a second window on every launch, so New Window goes
    through AppKit's open-untitled step instead.
    """
    # Sampled over time, not once. The spare window registers a few
    # milliseconds after the first, so a single check right after launch races
    # it and passes — this test did exactly that, and only caught the
    # regression once it watched for a while.
    deadline = time.time() + 5
    seen = []
    while time.time() < deadline:
        seen.append(len(_windows(app)))
        assert seen[-1] == 1, f"a spare window appeared at launch: counts={seen}"
        time.sleep(0.5)
    assert _windows(app)[0]["focused"]


def test_new_window_opens_another_and_close_removes_it(app):
    before = len(_windows(app))
    try:
        app.cli("window", "new")
        wait_for(
            lambda: len(_windows(app)) == before + 1,
            timeout=30,
            message="the new window to register",
        )

        app.cli("window", "close")
        wait_for(
            lambda: len(_windows(app)) == before,
            timeout=30,
            message="the focused window to close",
        )
    finally:
        _close_extra_windows(app, before)


def test_each_window_shows_its_own_project(app, tmp_path_factory):
    """The point of the feature: one project per window, so a window can sit in
    another Space without dragging the rest of the app with it.

    Also the regression test for the app-wide mirror. `AppState.activeProjectID`
    follows whichever window is key, so a background window must not redraw
    itself as whatever the frontmost one is showing.
    """
    second = tmp_path_factory.mktemp("second-project")
    name = f"win-{uuid.uuid4().hex[:8]}"
    app.cli("project", "create", str(second), "--name", name)

    before = len(_windows(app))
    try:
        app.cli("window", "new")
        wait_for(
            lambda: len(_windows(app)) == before + 1,
            timeout=30,
            message="the new window",
        )
        # Target the new window explicitly. Relying on it being FOCUSED is
        # not sound here: the harness drives the app without necessarily
        # bringing it frontmost, so no window may be key at all — which is
        # exactly why `project select` grew a `--window` flag.
        app.cli("project", "select", name, "--window", "2")
        time.sleep(2)

        projects = [_project_of(w) for w in _windows(app)]
        assert name in projects, f"the focused window should show {name}: {projects}"
        assert len(set(projects)) > 1, f"windows must not share one project: {projects}"
    finally:
        _close_extra_windows(app, before)


def test_a_window_reports_the_project_its_title_shows(app, tmp_path_factory):
    """The macOS Window menu lists windows by their NSWindow title and
    check-marks the key one — so listing every window there is a matter of each
    one titling itself, which `navigationTitle` does per window. This asserts
    the model side of that; the title itself is AppKit's to render.
    """
    windows = _windows(app)
    focused = [w for w in windows if w["focused"]]
    assert len(focused) == 1, f"exactly one window is key: {windows}"
    assert _project_of(focused[0]), "the key window should name a project"


def test_a_window_reports_its_own_sidebar_width(app):
    """Sidebar width is per window.

    Only the model side is asserted here. Driving a real divider drag needs an
    Accessibility grant, and the width the harness reads at launch comes from
    the developer's own debug UserDefaults domain (the harness isolates $HOME
    and the data dir, but `Preferences.defaults` resolves through the user
    record), so a fixed expected value would be a machine-specific assertion.
    `WindowStateTests` covers independence; the restore path is exercised by
    seeding a snapshot, which needs a second launch this suite does not do.
    """
    for window in _windows(app):
        width = window.get("sidebarWidth")
        assert width is not None, f"every window reports a width: {window}"
        assert 100 <= width <= 500, f"width out of any sane range: {width}"


def test_two_windows_on_one_tab_mirror_it(app):
    """A pane's NSView can live in one window, so two windows on the same tab
    must not fight over it — the second used to come up blank. Instead the
    second window renders a mirror view: `window list` reports the same tab
    for both, with exactly one marked `mirrored`.

    Everything is addressed by the FIRST window's project and by `--window`:
    the harness drives the app without necessarily making it active, so
    "the active project" and "the focused window" are not dependable here.
    """
    before = len(_windows(app))
    first = _windows(app)[0]
    project = first.get("projectID")
    assert project, f"the first window should show a project: {first}"
    tab = app.cli_json("tab", "new", "--project", project)["tabs"][0]
    try:
        app.cli("window", "new")
        wait_for(lambda: len(_windows(app)) == before + 1, timeout=30, message="the new window")
        second = str(before + 1)
        app.cli("project", "select", project, "--window", second)
        app.cli("tab", "select", tab["id"], "--project", project, "--window", "1")
        app.cli("tab", "select", tab["id"], "--project", project, "--window", second)

        def mirrored_pair():
            windows = _windows(app)[: before + 1]
            tabs = {w.get("tabID") for w in windows}
            mirrored = [w for w in windows if w.get("mirrored")]
            return windows if tabs == {tab["id"]} and len(mirrored) == 1 else None

        deadline = time.time() + 15
        while mirrored_pair() is None and time.time() < deadline:
            time.sleep(0.5)
        windows = _windows(app)
        assert mirrored_pair() is not None, f"one real view and one mirror expected: {windows}"
    finally:
        _close_extra_windows(app, before)
        # The janitor only sweeps the active project's tabs; this one may not
        # be there.
        app.cli("tab", "close", tab["id"], "--project", project, "--force", check=False)


def test_leadership_follows_window_focus_for_the_whole_tab(app):
    """Two windows on one tab: focusing a window hands the pty of EVERY pane in
    the tab to that window's view, and a split made while the mirror window is
    key (which rebuilds the mirror, detaching its old zmx clients — the state
    in which zmx makes the next attaching client leader) must not strand
    leadership. Asserted on the real panes' `leader` flags: false while the
    mirror window is key, true once the owning window is."""
    before = len(_windows(app))
    first = _windows(app)[0]
    project = first.get("projectID")
    assert project, f"the first window should show a project: {first}"
    tab = app.cli_json("tab", "new", "--project", project)["tabs"][0]

    def leaders():
        return {p["id"]: p["leader"] for p in app.panes(tab=tab["id"])}

    def all_are(value):
        flags = leaders()
        return flags if flags and all(v == value for v in flags.values()) else None

    try:
        source = app.panes(tab=tab["id"])[0]["id"]
        wait_for(lambda: app.pane_text(pane=source), timeout=60, message="the source surface")
        app.cli("pane", "split", "--direction", "down", "--pane", source)
        app.cli("window", "new")
        wait_for(lambda: len(_windows(app)) == before + 1, timeout=30, message="the new window")
        second = str(before + 1)
        app.cli("project", "select", project, "--window", second)
        app.cli("tab", "select", tab["id"], "--project", project, "--window", "1")
        app.cli("tab", "select", tab["id"], "--project", project, "--window", second)

        app.cli("window", "focus", second)
        wait_for(lambda: all_are(False), timeout=30, message="the mirror window to lead every pane")

        # Rebuild the mirror under the mirror window's feet.
        app.cli("pane", "split", "--direction", "right", "--pane", source)
        wait_for(lambda: len(leaders()) == 3, timeout=30, message="the third pane")
        wait_for(lambda: all_are(False), timeout=30, message="the rebuilt mirror to lead again")

        app.cli("window", "focus", "1")
        wait_for(lambda: all_are(True), timeout=30, message="the owning window to lead every pane")

        app.cli("window", "focus", second)
        wait_for(lambda: all_are(False), timeout=30, message="leadership to move back with focus")
    finally:
        app.cli("window", "focus", "1", check=False)
        _close_extra_windows(app, before)
        app.cli("tab", "close", tab["id"], "--project", project, "--force", check=False)
