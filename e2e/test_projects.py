"""Project verbs over the control plane, through the CLI's human output."""

import uuid


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
