<!-- page:
slug: extension-examples
title: Extension examples
nav: Examples
group: Extensions
description: Complete palettes for Macterm extensions that you can copy, for Docker containers and SSH hosts. The extensions in the Macterm repository are examples too.
-->

# Extension examples

Each example on this page is a complete palette. Save it at the path in its caption. Put an `extension.yaml` next to the `palettes/` folder (see [a first extension](/docs/extensions#a-first-extension)). Then press <kbd>⌘P</kbd> and select the palette. For each key, see the [palette reference](/docs/extension-palettes).

## Docker containers

```yaml title="~/.config/macterm/extensions/docker/palettes/docker.yaml"
name: Docker
description: Running containers, their logs and a shell in them
root: containers
nodes:
  containers:
    list: docker ps --format json
    title: .Names
    subtitle: .Image
    match: [.Names, .Image, .Status]
    export: { CONTAINER: .ID }
    enter: container
  container:
    items:
      - { title: Logs, subtitle: Follow in a split, action: { run: docker logs -f "$CONTAINER", in: split } }
      - { title: Shell, action: { run: docker exec -it "$CONTAINER" sh, in: split } }
      - { title: Stop, action: { run: docker stop "$CONTAINER" } }
```

## SSH

This palette lists the hosts that are named in `~/.ssh/config`. It leaves out wildcard patterns. It does not list hosts in an `Include`d file.

```yaml title="~/.config/macterm/extensions/ssh/palettes/ssh.yaml"
name: SSH
description: Hosts from ~/.ssh/config
root: hosts
nodes:
  hosts:
    list: awk 'tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i !~ /[*?!]/) print $i }' ~/.ssh/config
    export: { HOST: . }
    enter: host
  host:
    items:
      - { title: Connect, action: { run: ssh "$HOST" } }
      - { title: Connect in a split, action: { run: ssh "$HOST", in: split } }
```

## The extensions in the repository

Each extension in **Settings → Extensions** is also an example. Their files are in [`extensions/`](https://github.com/thdxg/macterm/tree/main/extensions) in the Macterm repository. Read them to see the larger parts of the format together:

- [**Kubernetes**](https://github.com/thdxg/macterm/blob/main/extensions/kubernetes/palettes/kubernetes.yaml) has namespaces, pods, deployments, services and contexts, on several screens. A `when:` check mutes the rows while the cluster does not answer. **Pods**, **Deployments** and **Services** each open from the first screen and from a namespace. Each listing passes `-A` or `-n "$NAMESPACE"`, and it does not paste the namespace into the command.
- [**Git**](https://github.com/thdxg/macterm/tree/main/extensions/git) has two palettes, for branches and for worktrees. A `cwd:` action opens a worktree in a new tab.
- [**Claude Code**](https://github.com/thdxg/macterm/tree/main/extensions/claude-code) puts fixed rows above a listing of sessions.
