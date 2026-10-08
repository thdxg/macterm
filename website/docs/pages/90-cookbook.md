<!-- page:
slug: cookbook
title: Cookbook
nav: Cookbook
group: Community
description: Community-shared Macterm workflows and recipes — read what others run, and post your own.
-->

# Cookbook

The [**Cookbook**](https://github.com/thdxg/macterm/discussions/categories/cookbook) is a discussion category for workflows and recipes. Anyone can post, anyone can borrow.

Three to start with, and a complete palette below:

- [**Navigating `nvim` and Macterm with the same keybinds**](https://github.com/thdxg/macterm/discussions/217) — one <kbd>ctrl</kbd>+<kbd>h/j/k/l</kbd> chord moves between nvim's splits and Macterm's panes.
- [**Driving an interactive program from a script**](https://github.com/thdxg/macterm/discussions/218) — `pane run`, `pane key`, and `pane dump` against a REPL or a pager.
- [**Giving a coding agent control of Macterm**](https://github.com/thdxg/macterm/discussions/219) — the original drop-in skill file. [`macterm skills`](/docs/cli#skills-for-coding-agents) now prints a fuller set.

## Kubernetes palette

An [extension](/docs/extensions) for browsing a cluster from <kbd>⌘P</kbd>, without typing resource names. Save it as `~/.config/macterm/palettes/kubernetes.yaml`, then open the palette and pick **Kubernetes**. It needs `kubectl` on the `PATH` your shell sets up, and works whatever your shell is.

```yaml title="~/.config/macterm/palettes/kubernetes.yaml"
# yaml-language-server: $schema=https://raw.githubusercontent.com/thdxg/macterm/main/assets/palette.schema.json
# Commands are POSIX sh, run in the active project's directory with the
# values picked above as environment variables.
name: Kubernetes
icon: shippingbox
description: Browse namespaces, pods, deployments, services and contexts
requires: [kubectl]
root: menu
nodes:
  menu:
    items:
      # Muted while the cluster doesn't answer; Contexts reads only your
      # kubeconfig, so it stays — switching context is often the fix.
      - title: Namespaces
        subtitle: Browse one namespace
        enter: namespaces
        when: &cluster { run: kubectl get --raw /readyz --request-timeout=2s, unavailable: Cluster unreachable }
      - { title: Pods, subtitle: All namespaces, enter: pods, when: *cluster }
      - { title: Deployments, subtitle: All namespaces, enter: deployments, when: *cluster }
      - { title: Services, subtitle: All namespaces, enter: services, when: *cluster }
      - { title: Contexts, subtitle: Switch the current context, enter: contexts }

  contexts:
    placeholder: Search contexts...
    list: kubectl config get-contexts -o name
    icon: point.3.connected.trianglepath.dotted
    export: { CONTEXT: . }
    action: { run: kubectl config use-context "$CONTEXT" }

  namespaces:
    placeholder: Search namespaces...
    list: kubectl get namespaces -o json
    rows: .items
    title: .metadata.name
    subtitle: .status.phase
    icon: folder
    export: { NAMESPACE: .metadata.name }
    enter: namespace-menu

  namespace-menu:
    items:
      - { title: Pods, enter: pods }
      - { title: Deployments, enter: deployments }
      - { title: Services, enter: services }
      - title: Set as current namespace
        action:
          run: kubectl config set-context --current --namespace "$NAMESPACE"

  # Pods, deployments and services are reached from the root (every
  # namespace) and from a namespace: each listing reads NAMESPACE when it is
  # set and lists all namespaces otherwise.
  pods:
    placeholder: Search pods by name, namespace, app or node...
    list: if [ -n "$NAMESPACE" ]; then set -- -n "$NAMESPACE"; else set -- -A; fi; kubectl get pods "$@" -o json
    rows: .items
    title: .metadata.name
    subtitle: .status.phase
    icon: shippingbox
    match: [.metadata.name, .metadata.namespace, .metadata.labels.app, .spec.nodeName]
    export: { POD: .metadata.name, NAMESPACE: .metadata.namespace }
    enter: pod-menu

  pod-menu:
    items:
      - title: Logs
        subtitle: Follow in a split
        action: { run: kubectl logs -f -n "$NAMESPACE" "$POD", in: split }
      - title: Shell
        subtitle: sh in the first container
        action: { run: kubectl exec -it -n "$NAMESPACE" "$POD" -- sh, in: split }
      - title: Describe
        action: { run: kubectl describe pod -n "$NAMESPACE" "$POD" }
      - title: Events
        action:
          run: kubectl get events -n "$NAMESPACE" --field-selector "involvedObject.name=$POD"

  deployments:
    placeholder: Search deployments...
    list: if [ -n "$NAMESPACE" ]; then set -- -n "$NAMESPACE"; else set -- -A; fi; kubectl get deployments "$@" -o json
    rows: .items
    title: .metadata.name
    subtitle: .metadata.namespace
    icon: square.stack.3d.up
    match: [.metadata.name, .metadata.namespace]
    export: { DEPLOYMENT: .metadata.name, NAMESPACE: .metadata.namespace }
    enter: deployment-menu

  deployment-menu:
    items:
      - title: Logs
        subtitle: Follow in a split
        action: { run: kubectl logs -f -n "$NAMESPACE" "deployment/$DEPLOYMENT", in: split }
      - title: Rollout status
        action: { run: kubectl rollout status -n "$NAMESPACE" "deployment/$DEPLOYMENT", in: split }
      - title: Restart
        subtitle: kubectl rollout restart
        action: { run: kubectl rollout restart -n "$NAMESPACE" "deployment/$DEPLOYMENT" }
      - title: Describe
        action: { run: kubectl describe deployment -n "$NAMESPACE" "$DEPLOYMENT" }

  services:
    placeholder: Search services...
    list: if [ -n "$NAMESPACE" ]; then set -- -n "$NAMESPACE"; else set -- -A; fi; kubectl get services "$@" -o json
    rows: .items
    title: .metadata.name
    subtitle: .spec.type
    icon: network
    match: [.metadata.name, .metadata.namespace, .spec.type, .spec.clusterIP]
    export:
      SERVICE: .metadata.name
      NAMESPACE: .metadata.namespace
      PORT: .spec.ports[0].port
    enter: service-menu

  service-menu:
    items:
      - title: Port-forward
        subtitle: Local port equals the service port
        action:
          run: kubectl port-forward -n "$NAMESPACE" "service/$SERVICE" "$PORT:$PORT"
          in: split
      - title: Describe
        action: { run: kubectl describe service -n "$NAMESPACE" "$SERVICE" }
      - title: Endpoints
        action: { run: kubectl get endpoints -n "$NAMESPACE" "$SERVICE" -o wide }
```

What each screen does:

- **Kubernetes**, the first screen, is a menu: browse one namespace, or go straight to pods, deployments or services across all of them, or switch contexts. While the cluster doesn't answer, everything but Contexts is muted and says *Cluster unreachable* ([`when:`](/docs/custom-palettes#when-a-palette-cant-be-used)).
- **Contexts** lists `kubectl config get-contexts`. Picking one runs `kubectl config use-context` in a new tab.
- **Namespaces** lists the cluster's namespaces with their phase. Picking one opens a menu for it, and every screen below is scoped to that namespace.
- **The namespace's menu** opens its pods, deployments or services, or makes it the current context's namespace.
- **Pods** lists pods with their phase, searchable by name, namespace, `app` label or node. A pod's menu follows its logs or opens a shell in a split, or describes it or lists its events in a new tab.
- **Deployments** lists deployments with their namespace. A deployment's menu follows its logs, watches its rollout, restarts it, or describes it.
- **Services** lists services with their type. A service's menu port-forwards its first port to the same local port in a split, or describes it, or lists its endpoints.

**Pods, Deployments and Services are each one node reached from two places.** From the first screen there is no `NAMESPACE`, so the listing passes `-A`. From a namespace, it passes `-n "$NAMESPACE"`. The `if … set --` line builds the arguments for either case without pasting the namespace into the command.

## Post your own

[Start a Cookbook topic](https://github.com/thdxg/macterm/discussions/new?category=cookbook). What makes a recipe easy to adopt:

- **Lead with what it gets you** — the annoyance it removes, before the config.
- **Include the whole thing** — the full [layout YAML](/docs/declarative-layouts), keybind, or script.
- **Name the minimum version** if it leans on something recent, and list any other tools needed.

> Bugs belong in [Issues](https://github.com/thdxg/macterm/issues), questions in [Q&A](https://github.com/thdxg/macterm/discussions/categories/q-a), feature requests in [Ideas](https://github.com/thdxg/macterm/discussions/categories/ideas).
