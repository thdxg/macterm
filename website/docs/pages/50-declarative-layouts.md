<!-- page:
slug: declarative-layouts
title: Declarative layouts
nav: Declarative layouts
group: Projects & sessions
description: Describe a project's tabs, splits, and per-pane commands in YAML.
-->

# Declarative layouts

Describe a project's tabs, splits, and per-pane commands in YAML. Files live in `~/.config/macterm/projects/`, one per project, matched by `path` — the filename is cosmetic.

```yaml title="~/.config/macterm/projects/myapp.yaml"
name: "MyApp"
path: "~/dev/myapp"
tabs:
  - run: "npm run dev"
  - name: "Dev"
    split:
      direction: horizontal
      ratio: 0.6
      first:  { cwd: "./api", run: "npm run dev" }
      second: {} # plain shell pane
```

Each tab is either a leaf pane (`cwd` / `run` / `shell`) or a `split` with a `direction`, a `ratio`, and `first` / `second` children. A bare `{}` is a plain shell.

## Applying and saving

| Command palette | Effect |
| --- | --- |
| **Save layout** | Writes your current workspace to the file. |
| **Apply layout** | Reconciles the live workspace toward the file — matching panes are kept, drifted ones restart. |

Selecting a project or relaunching Macterm restores your last session, not the file. The file takes effect only when you run **Apply layout**.

## Remote projects

Set `path` to a remote spec and the tabs spawn on that host. Add `zmxPath` only if auto-detection fails.

```yaml
path: "devbox:~/dev/api"
zmxPath: "~/bin/zmx"
```

See [remote projects](/docs/remote-projects).
