"""Project verbs over the control plane, through the CLI's human output."""

import json
import uuid
from pathlib import Path

from _harness import MactermHarness, wait_for


def test_a_single_project_reply_prints_its_list_ref(app, tmp_path):
    """A one-project reply prints the project's own `project:N` — its
    position in `project list`, the number `--project` resolves — not its row
    in the reply, which read `project:1` wherever the project really sat. The
    harness's own project is listed first, so a created one never is: the
    printed ref can only be right if the app supplied it. Covers create and
    rename; select shares the same reply but would move the active project
    under later tests."""
    name = f"ref-{uuid.uuid4().hex[:8]}"
    created = app.cli("project", "create", str(tmp_path), "--name", name).stdout
    project = next(p for p in app.cli_json("project", "list")["projects"] if p["name"] == name)
    try:
        ref = f"project:{project['index']}"
        assert project["index"] > 1
        assert created.split()[0] == ref

        # The printed ref reaches the project it was printed for.
        renamed = app.cli("project", "rename", ref, f"{name}-renamed").stdout
        assert renamed.split()[0] == ref
        names = {p["id"]: p["name"] for p in app.cli_json("project", "list")["projects"]}
        assert names[project["id"]] == f"{name}-renamed"
    finally:
        app.cli("project", "remove", project["id"], check=False)


def test_projects_without_folders_keep_tabs_layouts_and_sessions_after_restart(app):
    instance = MactermHarness(app.app, home_prefix="macterm-folderless-e2e-")
    try:
        instance.launch()
        instance.open_project()
        instance.wait_for_socket()
        first = instance.cli_json("project", "create", "--name", "Scratch", "--select")["projects"][0]
        assert first["path"] == ""
        assert first["active"]
        pane = instance.panes()[0]
        wait_for(lambda: instance.pane_text(pane=pane["id"]), timeout=60, message="the first shell")

        # Check the shell's actual cwd. Assemble the marker at run time so
        # the echoed command cannot satisfy the assertion.
        nonce = uuid.uuid4().hex[:10]
        instance.pane_run(f'/bin/sh -c "printf cwd-%s: {nonce}; pwd"', pane=pane["id"])
        home_paths = {instance.home, str(Path(instance.home).resolve())}
        wait_for(
            lambda: any(
                f"cwd-{nonce}:{home}" in (instance.pane_text(pane=pane["id"]) or "") for home in home_paths
            ),
            message="the shell starting in the isolated home folder",
        )
        instance.cli("pane", "split", "--pane", pane["id"], "--direction", "right")
        instance.cli("tab", "new", "--project", first["id"])
        tabs = instance.cli_json("tab", "list", "--project", first["id"])["tabs"]
        assert len(tabs) == 2
        assert sorted(tab["paneCount"] for tab in tabs) == [1, 2]
        instance.cli("layout", "save", "--project", first["id"])

        second = instance.cli_json("project", "create", "--name", "Scratch", "--select")["projects"][0]
        assert second["path"] == ""
        assert second["id"] != first["id"]
        instance.cli("layout", "save", "--project", second["id"])
        layouts = list((Path(instance.home) / ".config/macterm/projects").glob("*.yaml"))
        assert len(layouts) == 2
        contents = [path.read_text() for path in layouts]
        for project in [first, second]:
            assert sum(project["id"].lower() in text.lower() for text in contents) == 1
        assert all("\npath:" not in text for text in contents)

        instance.cli("project", "rename", first["id"], "Renamed")
        instance.cli("layout", "apply", "--project", first["id"], "--force")
        before = instance.cli_json("pane", "list", "--project", first["id"])["panes"]
        sessions = {pane["session"] for pane in before}
        assert len(sessions) == 3
        instance.kill()
        instance.launch()
        instance.wait_for_socket()

        # The socket answers before the snapshot restores. A select before
        # the restore builds a new default workspace, so wait until the
        # restored workspace lists its panes first.
        def restored_sessions():
            result = instance.cli("pane", "list", "--project", first["id"], "--json", check=False)
            if result.returncode != 0:
                return None
            return {pane["session"] for pane in json.loads(result.stdout).get("panes") or []} or None

        assert wait_for(restored_sessions, message="the restored workspace of the project") == sessions
        projects = instance.cli_json("project", "list")["projects"]
        restored = next(project for project in projects if project["id"] == first["id"])
        assert restored["name"] == "Renamed"
        assert restored["path"] == ""
        instance.cli("project", "select", first["id"])
        after = instance.cli_json("pane", "list", "--project", first["id"])["panes"]
        assert {pane["session"] for pane in after} == sessions
    finally:
        instance.cleanup()
