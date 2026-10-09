<!-- page:
slug: cookbook
title: Cookbook
nav: Cookbook
group: Community
description: Workflows and recipes that the community shares. Read what others run, and post your own.
-->

# Cookbook

The [**Cookbook**](https://github.com/thdxg/macterm/discussions/categories/cookbook) is a discussion category for workflows and recipes. Anyone can post a recipe, and anyone can use one.

Here are three recipes to start with. A complete palette follows them.

- [**Navigating `nvim` and Macterm with the same keybinds**](https://github.com/thdxg/macterm/discussions/217) One <kbd>ctrl</kbd>+<kbd>h/j/k/l</kbd> keybind moves between the splits of nvim and the panes of Macterm.
- [**Driving an interactive program from a script**](https://github.com/thdxg/macterm/discussions/218) Use `pane run`, `pane key` and `pane dump` with a REPL or a pager.
- [**Giving a coding agent control of Macterm**](https://github.com/thdxg/macterm/discussions/219) This is the original skill file that you can drop in. [`macterm skills`](/docs/cli#skills-for-coding-agents) now prints a fuller set.

## Kubernetes palette

An [extension](/docs/extensions) to browse a cluster from <kbd>⌘P</kbd>, with no need to type resource names. Save it as `~/.config/macterm/palettes/kubernetes.yaml`. Then open the palette and select **Kubernetes**. It needs `kubectl` in the `PATH` that your shell sets up. It works with any shell.

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

- **Kubernetes**, the first screen, is a menu. You can browse one namespace. You can go straight to pods, deployments or services in all namespaces. You can also switch contexts. While the cluster does not answer, every row except Contexts is muted and says *Cluster unreachable* ([`when:`](/docs/extensions#when-a-palette-cant-be-used)).
- **Contexts** lists `kubectl config get-contexts`. When you select a context, `kubectl config use-context` runs in a new tab.
- **Namespaces** lists the namespaces of the cluster with their phase. When you select one, a menu for it opens. Every screen below it uses that namespace.
- **The menu of a namespace** opens its pods, deployments or services. It can also make the namespace the namespace of the current context.
- **Pods** lists pods with their phase, searchable by name, namespace, `app` label or node. The menu of a pod follows its logs or opens a shell in a split. It can also describe the pod, or list its events, in a new tab.
- **Deployments** lists deployments with their namespace. The menu of a deployment follows its logs, watches its rollout, restarts it, or describes it.
- **Services** lists services with their type. The menu of a service forwards its first port to the same local port in a split. It can also describe the service or list its endpoints.

**Pods, Deployments and Services each have two entry points.** From the first screen, there is no `NAMESPACE`, so the listing passes `-A`. From a namespace, it passes `-n "$NAMESPACE"`. The `if … set --` line builds the arguments for both cases. It does not paste the namespace into the command.

## Post your own

[Start a Cookbook topic](https://github.com/thdxg/macterm/discussions/new?category=cookbook). These points make a recipe easy to use:

- **Start with the benefit.** Say what problem it removes, before you show the config.
- **Include everything.** Add the full [layout YAML](/docs/declarative-layouts), keybind or script.
- **Name the minimum version** if the recipe needs a recent feature. List any other tools that it needs.

> Report bugs in [Issues](https://github.com/thdxg/macterm/issues). Ask questions in [Q&A](https://github.com/thdxg/macterm/discussions/categories/q-a). Request features in [Ideas](https://github.com/thdxg/macterm/discussions/categories/ideas).
