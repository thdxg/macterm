<!-- page:
slug: declarative-layouts
title: Declarative layouts
nav: Declarative layouts
group: Projects & sessions
description: Describe the tabs, splits and commands of a project in YAML.
-->

# Declarative layouts

Describe the tabs, splits and commands of a project in YAML. The files are in `~/.config/macterm/projects/`, one file for each project. Macterm matches a file to a project by `path`, or by `id` for a project without a folder. The file name does not matter.

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

Each tab is a leaf pane (`cwd`, `run` and `shell`) or a `split`. A `split` has a `direction`, a `ratio`, and the children `first` and `second`. A bare `{}` is a plain shell.

## Applying and saving

| Command palette | Effect |
| --- | --- |
| **Save layout** | Writes your current workspace to the file. |
| **Apply layout** | Changes the live workspace to match the file. Macterm keeps the panes that match. It starts again the panes that are different. |

When you select a project or start Macterm again, Macterm restores your last session. It does not read the file. The file has an effect only when you run **Apply layout**.

## Remote projects

Set `path` to a remote spec. The tabs then start on that host. Add `zmxPath` only if Macterm cannot find zmx by itself.

```yaml
path: "devbox:~/dev/api"
zmxPath: "~/bin/zmx"
```

See [remote projects](/docs/remote-projects).

## Projects without folders

Select **New Project → Without Folder…** and enter a name. The first terminal starts in your home folder. New tabs and splits follow your directory-inheritance settings. **Files**, **Copy Path**, **Worktrees** and **Replace Project Path with Current Directory** need a project folder.

**Save Layout** records the project ID as `id` and omits `path`. Keep that ID when you edit the layout or rename the project. Two projects with the same name have separate IDs and layout files. Relative `cwd` values start from your home folder. Absolute paths and paths that start with `~` work too.

The project ID also lets **Settings → Projects → Layouts → Create Project** restore a project from its saved file.
