<!-- page:
slug: declarative-layouts
title: Declarative layouts
nav: Declarative layouts
group: Projects
description: Describe a project's tabs, splits, and per-pane commands in YAML.
-->

# Declarative layouts

Describe a project's tabs, split layout, and the process each pane runs in a YAML file, and Macterm builds the workspace from it. Project files live in `~/.config/macterm/projects/`, one per project — they're matched to a project by their `path`, not their filename, so the filename is just cosmetic.

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

Each tab is a layout node: a leaf pane (`cwd` / `run` / `shell`) or a `split` with a `direction`, a `ratio`, and `first` / `second` children. A bare `{}` is a plain shell.

Run **Save layout** from the palette to write your current workspace out, or **Apply layout** to reconcile the live workspace toward the file — matching panes are kept, only ones that drifted are restarted.

A `path` can also be a remote spec (`devbox:~/dev/api`), declaring a [remote project](/docs/remote-projects) whose tabs spawn on that host — with an optional top-level `zmxPath` when zmx needs an explicit location there.

> The older in-project `.macterm/layout.yaml` still seeds a project on first open, but it's deprecated in favor of the central files above.
