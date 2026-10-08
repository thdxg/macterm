import Foundation
@testable import Macterm
import Testing

/// A custom palette's screens (`CustomPaletteScope`) over a store of files,
/// with the listing command replaced by canned output.
@MainActor
struct CustomPaletteScopeTests {
    /// A store in a temp directory holding the Kubernetes example and a
    /// broken file, and a context whose `AppState` reads from it.
    private func makeContext(files: [String: String]) throws -> (PaletteContext, CustomPaletteStore, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-palette-tests-\(UUID().uuidString)", isDirectory: true)
        let config = base.appendingPathComponent("config", isDirectory: true)
        let palettes = config.appendingPathComponent("palettes", isDirectory: true)
        try FileManager.default.createDirectory(at: palettes, withIntermediateDirectories: true)
        for (name, text) in files {
            try text.write(to: palettes.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: base.appendingPathComponent("workspaces.json")),
            projectFiles: ProjectFileStore(
                directoryURL: base.appendingPathComponent("projects", isDirectory: true),
                configDirectoryURL: config
            )
        )
        let store = ProjectStore(fileURL: base.appendingPathComponent("projects.json"))
        let project = Project(name: "api", path: "/tmp", sortOrder: 0)
        store.add(project)
        state.selectProject(project)
        return (PaletteContext(appState: state, projectStore: store), state.customPalettes, palettes)
    }

    private static let podsJSON = """
    {"items": [
      {"metadata": {"name": "api-1", "namespace": "prod", "labels": {"app": "api"}}, "status": {"phase": "Running"}},
      {"metadata": {"name": "web-1", "namespace": "prod", "labels": {"app": "web"}}, "status": {"phase": "Running"}}
    ]}
    """

    /// A runner that answers from `outputs` by command and records what it
    /// was asked, including the environment. The login shell is always
    /// handed the trampoline, so the command is the one it carries.
    private final class Recorder: @unchecked Sendable {
        // `when:` checks run concurrently.
        private let lock = NSLock()
        private var _calls: [(command: String, environment: [String: String], cwd: String?)] = []
        private var _outputs: [String: CustomPaletteCommandResult] = [:]
        var calls: [(command: String, environment: [String: String], cwd: String?)] { lock.withLock { _calls } }
        var outputs: [String: CustomPaletteCommandResult] {
            get { lock.withLock { _outputs } }
            set { lock.withLock { _outputs = newValue } }
        }

        var runner: CustomPaletteCommandRunner {
            { [self] line, environment, cwd in
                #expect(line == CustomPaletteScript.trampoline)
                let command = environment[CustomPaletteScript.commandVariable] ?? ""
                return lock.withLock {
                    _calls.append((command, environment, cwd))
                    return _outputs[command] ?? CustomPaletteCommandResult(stdout: "", stderr: "no canned output for \(command)", status: 1)
                }
            }
        }
    }

    private static let ok = CustomPaletteCommandResult(stdout: "", stderr: "", status: 0)
    private static let down = CustomPaletteCommandResult(stdout: "", stderr: "unreachable", status: 1)

    private func settle() async {
        for _ in 0 ..< 50 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A palette kept by a dotfiles manager is a link: saving the file it
    /// points at changes the target's date, never the link's.
    @Test
    func an_edit_through_a_symlinked_file_is_seen() throws {
        let (_, store, dir) = try makeContext(files: [:])
        let target = dir.deletingLastPathComponent().appendingPathComponent("dotfiles-git.yaml")
        try "name: Before\nnodes: { root: { list: ls, action: { copy: . } } }".write(to: target, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("git.yaml"), withDestinationURL: target)
        store.reload()
        #expect(store.palette(id: "git")?.name == "Before")

        try "name: After\nnodes: { root: { list: ls, action: { copy: . } } }".write(to: target, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: target.path)
        store.reloadIfChanged()
        #expect(store.palette(id: "git")?.name == "After")
    }

    /// `git.yaml` and `git.yml` would share an id; the second says so
    /// rather than shadowing the first unseen.
    @Test
    func two_files_with_one_name_keep_the_first_and_explain_the_second() throws {
        let palette = "name: Git\nnodes: { root: { list: ls, action: { copy: . } } }"
        let (_, store, _) = try makeContext(files: ["git.yaml": palette, "git.yml": palette])
        #expect(store.entries.map(\.id) == ["git", "git.yml"])
        #expect(store.palette(id: "git")?.name == "Git")
        #expect(store.entry(id: "git.yml")?.failure?.errorDescription == "another file is already the palette git; rename one")
    }

    @Test
    func the_store_reads_every_file_and_keeps_a_broken_one_with_its_error() throws {
        let (_, store, dir) = try makeContext(files: [
            "kubernetes.yaml": CustomPaletteFileTests.kubernetes,
            "broken.yml": "name: Broken\nnodes: { root: { list: ls } }",
            "notes.txt": "not a palette",
        ])
        #expect(store.entries.map(\.id) == ["broken", "kubernetes"], "by file name, yaml and yml alike, nothing else")
        #expect(store.palette(id: "kubernetes")?.name == "Kubernetes")
        #expect(store.entry(id: "broken")?.failure?.errorDescription == "root: needs enter: or action:")
        #expect(store.entry(id: "broken")?.pill.title == "Broken", "a broken file is named as far as its YAML parses")
        #expect(store.rootTarget(id: "kubernetes") == CustomPaletteTarget(
            paletteID: "kubernetes", node: "menu", exports: [:], pill: PalettePill(title: "Kubernetes", systemImage: "shippingbox")
        ))
        #expect(store.rootTarget(id: "broken")?.node == "root", "a broken file still opens: on its error")
        #expect(store.rootTarget(id: "nope") == nil)
        #expect(PaletteHotkeys.shared.paletteIDs == ["broken", "kubernetes"], "the keybind table learns the files")

        // A save is seen on the next reload-if-changed; an untouched folder is left alone.
        try "name: Fixed\nnodes: { root: { list: ls, action: { copy: . } } }"
            .write(to: dir.appendingPathComponent("broken.yml"), atomically: true, encoding: .utf8)
        store.reloadIfChanged()
        #expect(store.palette(id: "broken")?.name == "Fixed")
    }

    @Test
    func a_menu_lists_its_items_and_entering_one_names_the_next_frame_after_it() throws {
        let (context, store, _) = try makeContext(files: ["kubernetes.yaml": CustomPaletteFileTests.kubernetes])
        let root = try #require(store.rootTarget(id: "kubernetes"))
        let scope = CustomPaletteScope(target: root, runner: Recorder().runner)
        scope.activate(context: context) {}
        #expect(scope.loading == nil, "a menu has nothing to list")

        let items = scope.sections(for: PaletteQuery(raw: ""), context: context).flatMap(\.items)
        #expect(items.map(\.title) == ["Namespaces", "Pods"])
        #expect(items.map(\.icon) == ["shippingbox", "shippingbox"], "rows wear the palette's glyph by default")
        guard case let .custom(next)? = items[0].opensScope else { Issue.record("Namespaces does not enter a node")
            return
        }
        #expect(next.node == "namespaces")
        #expect(next.pill == PalettePill(title: "Namespaces", systemImage: "shippingbox"), "the pill is the row that was picked")
        #expect(next.exports.isEmpty)

        let filtered = scope.sections(for: PaletteQuery(raw: "pod"), context: context).flatMap(\.items)
        #expect(filtered.map(\.title) == ["Pods"])
    }

    static let sessions = """
    name: Sessions
    nodes:
      root:
        items:
          - { title: New Session, action: { run: claude }, alt: { title: New Session in a Split, run: claude, in: split } }
          - { title: Copy Hello, action: { copy: hello }, alt: { open: "https://example.com" } }
        list: printf '%s\\n' one two
        export: { SESSION: . }
        action: { run: claude --resume "$SESSION" }
        alt: { run: claude --resume "$SESSION", in: split }
    """

    @Test
    func a_node_with_items_and_a_listing_shows_the_items_first_and_at_once() async throws {
        let (context, _, _) = try makeContext(files: ["sessions.yaml": Self.sessions])
        let recorder = Recorder()
        recorder.outputs["printf '%s\\n' one two"] = CustomPaletteCommandResult(stdout: "one\ntwo\n", stderr: "", status: 0)
        let target = CustomPaletteTarget(
            paletteID: "sessions",
            node: "root",
            exports: [:],
            pill: PalettePill(title: "Sessions", systemImage: "x")
        )
        let scope = CustomPaletteScope(target: target, runner: recorder.runner)
        scope.activate(context: context) {}
        #expect(scope.loading != nil, "the listing runs")
        #expect(
            scope.sections(for: PaletteQuery(raw: ""), context: context).flatMap(\.items).map(\.title) == ["New Session", "Copy Hello"],
            "the written rows don't wait for the listing"
        )
        await settle()
        let items = scope.sections(for: PaletteQuery(raw: ""), context: context).flatMap(\.items)
        #expect(items.map(\.title) == ["New Session", "Copy Hello", "one", "two"])
        #expect(
            items.map(\.alt?.title) == ["New Session in a Split", "Open", "Run in a Split", "Run in a Split"],
            "an alt without a title is named after what it does"
        )
    }

    @Test
    func a_listing_runs_its_command_once_with_the_exports_in_the_environment_and_filters_the_cached_rows() async throws {
        let (context, _, _) = try makeContext(files: ["kubernetes.yaml": CustomPaletteFileTests.kubernetes])
        let recorder = Recorder()
        let command = "if [ -n \"$NAMESPACE\" ]; then set -- -n \"$NAMESPACE\"; else set -- -A; fi; kubectl get pods \"$@\" -o json"
        recorder.outputs[command] = CustomPaletteCommandResult(stdout: Self.podsJSON, stderr: "", status: 0)
        let target = CustomPaletteTarget(
            paletteID: "kubernetes", node: "pods", exports: ["NAMESPACE": "prod"],
            pill: PalettePill(title: "Pods", systemImage: "shippingbox")
        )
        let scope = CustomPaletteScope(target: target, runner: recorder.runner)
        var redraws = 0
        scope.activate(context: context) { redraws += 1 }
        #expect(scope.loading?.message == "Listing Pods…")
        #expect(scope.sections(for: PaletteQuery(raw: ""), context: context).isEmpty)

        await settle()
        #expect(scope.loading == nil)
        #expect(scope.failure == nil)
        #expect(redraws == 2)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls[0].command == command)
        #expect(recorder.calls[0].environment["NAMESPACE"] == "prod")
        #expect(recorder.calls[0].environment[CustomPaletteEnvironment.projectNameKey] == "api")
        #expect(recorder.calls[0].environment[CustomPaletteEnvironment.projectDirectoryKey] == "/tmp")
        #expect(recorder.calls[0].cwd == "/tmp")

        let all = scope.sections(for: PaletteQuery(raw: ""), context: context).flatMap(\.items)
        #expect(all.map(\.title) == ["api-1", "web-1"])
        #expect(all.map(\.subtitle) == ["Running", "Running"])
        #expect(all[0].opensScope == nil, "pods act; they don't enter")
        let byApp = scope.sections(for: PaletteQuery(raw: "web"), context: context).flatMap(\.items)
        #expect(byApp.map(\.title) == ["web-1"], "match: fields are searched, nothing is listed again")
        #expect(recorder.calls.count == 1)

        // Told again when its frame returns to the top: nothing restarts.
        scope.activate(context: context) { redraws += 1 }
        #expect(recorder.calls.count == 1)
    }

    @Test
    func entering_from_a_listing_row_carries_its_exports_down() async throws {
        let (context, _, _) = try makeContext(files: ["kubernetes.yaml": CustomPaletteFileTests.kubernetes])
        let recorder = Recorder()
        recorder.outputs["kubectl get ns -o json"] = CustomPaletteCommandResult(
            stdout: #"{"items": [{"metadata": {"name": "prod"}}, {"metadata": {"name": "staging"}}]}"#, stderr: "", status: 0
        )
        let target = CustomPaletteTarget(
            paletteID: "kubernetes",
            node: "namespaces",
            exports: [:],
            pill: PalettePill(title: "Namespaces", systemImage: "shippingbox")
        )
        let scope = CustomPaletteScope(target: target, runner: recorder.runner)
        scope.activate(context: context) {}
        await settle()
        let rows = scope.sections(for: PaletteQuery(raw: ""), context: context).flatMap(\.items)
        #expect(rows.map(\.title) == ["prod", "staging"])
        guard case let .custom(next)? = rows[1].opensScope else { Issue.record("a namespace does not enter its menu")
            return
        }
        #expect(next.node == "namespace-menu")
        #expect(next.exports == ["NAMESPACE": "staging"])
        #expect(next.pill.title == "staging")
    }

    @Test
    func a_failing_command_reports_why_and_a_retry_runs_it_again() async throws {
        let (context, _, _) = try makeContext(files: ["kubernetes.yaml": CustomPaletteFileTests.kubernetes])
        let recorder = Recorder()
        recorder.outputs["kubectl get ns -o json"] = CustomPaletteCommandResult(
            stdout: "", stderr: "error: You must be logged in to the server (Unauthorized)", status: 1
        )
        let target = CustomPaletteTarget(
            paletteID: "kubernetes",
            node: "namespaces",
            exports: [:],
            pill: PalettePill(title: "Namespaces", systemImage: "shippingbox")
        )
        let scope = CustomPaletteScope(target: target, runner: recorder.runner)
        scope.activate(context: context) {}
        await settle()
        #expect(scope.failure == PaletteFailure(
            title: "Couldn't list Namespaces",
            detail: "error: You must be logged in to the server (Unauthorized)"
        ))
        #expect(scope.sections(for: PaletteQuery(raw: ""), context: context).isEmpty)
        #expect(recorder.calls.count == 1, "nothing is required, so nothing is probed")

        // Activation after a failure does not retry on its own; ⌘R does.
        scope.activate(context: context) {}
        #expect(recorder.calls.count == 1)
        recorder.outputs["kubectl get ns -o json"] = CustomPaletteCommandResult(stdout: "not json at all", stderr: "", status: 0)
        scope.retry()
        #expect(scope.failure == nil)
        #expect(scope.loading != nil)
        await settle()
        #expect(recorder.calls.count == 2)
        #expect(scope.failure?.title == "Couldn't read Namespaces")
        #expect(scope.failure?.detail == "rows: .items names a path, but the output isn't JSON")
    }

    @Test
    func a_failing_listing_names_the_required_programs_that_are_missing() async throws {
        let (context, _, _) = try makeContext(files: ["pods.yaml": """
        name: Pods
        requires: [kubectl, jq]
        nodes: { root: { list: kubectl get pods -o json | jq .items, action: { copy: . } } }
        """])
        let recorder = Recorder()
        recorder.outputs["kubectl get pods -o json | jq .items"] = CustomPaletteCommandResult(
            stdout: "", stderr: "bash: kubectl: command not found", status: 127
        )
        recorder.outputs[CustomPaletteRequirements.probe] = CustomPaletteCommandResult(stdout: "kubectl\n", stderr: "", status: 0)
        let scope = CustomPaletteScope(
            target: CustomPaletteTarget(paletteID: "pods", node: "root", exports: [:], pill: PalettePill(title: "Pods", systemImage: "x")),
            runner: recorder.runner
        )
        scope.activate(context: context) {}
        await settle()
        #expect(scope.failure == PaletteFailure(
            title: "Couldn't list Pods",
            detail: "This palette needs kubectl, which isn't on your PATH."
        ))
        #expect(recorder.calls.map(\.command) == ["kubectl get pods -o json | jq .items", CustomPaletteRequirements.probe])
        #expect(recorder.calls[1].environment[CustomPaletteRequirements.variable] == "kubectl jq")
        #expect(recorder.calls[1].environment[CustomPaletteEnvironment.projectDirectoryKey] == "/tmp", "probed on the listing's PATH")

        // Everything there: the listing's own error stands.
        recorder.outputs[CustomPaletteRequirements.probe] = CustomPaletteCommandResult(stdout: "", stderr: "", status: 0)
        scope.retry()
        await settle()
        #expect(scope.failure?.detail == "bash: kubectl: command not found")
    }

    @Test
    func entering_a_broken_palette_shows_its_error_and_a_retry_rereads_the_file() throws {
        let (context, store, dir) = try makeContext(files: ["broken.yml": "name: Broken\nnodes: { root: { list: ls } }"])
        let target = try #require(store.rootTarget(id: "broken"))
        let scope = CustomPaletteScope(target: target, runner: Recorder().runner)
        var redraws = 0
        scope.activate(context: context) { redraws += 1 }
        #expect(scope.failure == PaletteFailure(title: "Couldn't read broken.yml", detail: "root: needs enter: or action:"))
        #expect(scope.loading == nil)
        #expect(scope.sections(for: PaletteQuery(raw: ""), context: context).isEmpty)

        try "name: Broken\nnodes: { root: { items: [{ title: Fixed, action: { copy: x } }] } }"
            .write(to: dir.appendingPathComponent("broken.yml"), atomically: true, encoding: .utf8)
        scope.retry()
        #expect(scope.failure == nil, "⌘R reads the file again")
        #expect(redraws == 1)
        #expect(scope.sections(for: PaletteQuery(raw: ""), context: context).flatMap(\.items).map(\.title) == ["Fixed"])
    }

    @Test
    func the_rows_of_a_result_name_each_kind_of_failure() throws {
        let listing = try #require(CustomPaletteFileTests.palette(CustomPaletteFileTests.kubernetes).nodes["pods"]?.listing)
        #expect(CustomPaletteScope.rows(from: .init(stdout: "", stderr: "", status: 127), listing: listing, title: "Pods")
            == .failure(PaletteFailure(title: "Couldn't list Pods", detail: "The command exited with status 127.")))
        #expect(CustomPaletteScope.rows(from: .init(stdout: "{\"items\": 3}", stderr: "", status: 0), listing: listing, title: "Pods")
            == .failure(PaletteFailure(title: "Couldn't read Pods", detail: "rows: .items isn't an array")))
        #expect(
            CustomPaletteScope.rows(from: .init(stdout: Self.podsJSON, stderr: "warning", status: 0), listing: listing, title: "Pods")
                .map(\.count) == .success(2),
            "stderr beside good output is not a failure"
        )
    }

    @Test
    func a_run_action_hands_a_local_pane_its_command_in_the_environment_never_typed() throws {
        let (context, _, _) = try makeContext(files: [:])
        let state = context.appState
        let project = try #require(context.projectStore.projects.first)
        CustomPaletteActions.perform(
            .run(command: "\n  kubectl logs -f \"$POD\"", in: .tab),
            operand: nil,
            exports: ["POD": "api-1"],
            appState: state,
            projects: context.projectStore.projects
        )
        let pane = try #require(state.focusedPane(for: project.id))
        #expect(pane.command == nil, "nothing is typed at the prompt")
        #expect(pane.env?[CustomPaletteScript.commandVariable] == "kubectl logs -f \"$POD\"")
        #expect(pane.env?["POD"] == "api-1")
        #expect(pane.env?[CustomPaletteEnvironment.projectDirectoryKey] == "/tmp")

        let remote = Project(name: "box", path: "me@box:/srv", sortOrder: 1)
        context.projectStore.add(remote)
        state.selectProject(remote)
        CustomPaletteActions.perform(
            .run(command: "htop", in: .tab),
            operand: nil,
            exports: [:],
            appState: state,
            projects: context.projectStore.projects
        )
        let remotePane = try #require(state.focusedPane(for: remote.id))
        #expect(remotePane.command == "htop", "ssh carries no environment, so a remote pane still types it")
        #expect(remotePane.env?[CustomPaletteScript.commandVariable] == nil)
    }

    /// A pinned tab belongs to no project: the command splits beside it,
    /// untyped, in the pinned tabs' home — never a tab, which would be
    /// pinned itself.
    @Test
    func a_run_action_with_a_pinned_tab_active_splits_beside_it() throws {
        let (context, _, _) = try makeContext(files: [:])
        let state = context.appState
        state.selectPinnedProject()
        _ = try #require(state.createTab(projectID: PinnedTabs.projectID, projectPath: PinnedTabs.fallbackRoot))
        let before = state.workspaces[PinnedTabs.projectID]?.tabs.count
        CustomPaletteActions.perform(
            .run(command: "htop", in: .tab),
            operand: nil,
            exports: ["HOST": "a"],
            appState: state,
            projects: context.projectStore.projects
        )
        #expect(state.workspaces[PinnedTabs.projectID]?.tabs.count == before, "no new pinned tab")
        let panes = try #require(state.workspaces[PinnedTabs.projectID]?.activeTab?.splitRoot.allPanes())
        #expect(panes.count == 2)
        let pane = try #require(state.focusedPane(for: PinnedTabs.projectID))
        #expect(pane.command == nil)
        #expect(pane.env?[CustomPaletteScript.commandVariable] == "htop")
        #expect(pane.env?["HOST"] == "a")
    }

    /// An `open:` path a listing printed relative to the project (`git
    /// ls-files`) opens there, not under the app's `/`.
    @Test
    func a_relative_open_path_resolves_against_the_project() throws {
        let (context, _, _) = try makeContext(files: [:])
        let projects = context.projectStore.projects
        #expect(CustomPaletteActions.fileURL("src/main.swift", appState: context.appState, projects: projects)
            .path == "/tmp/src/main.swift")
        #expect(CustomPaletteActions.fileURL("/etc/hosts", appState: context.appState, projects: projects).path == "/etc/hosts")
        #expect(CustomPaletteActions.fileURL("~/x", appState: context.appState, projects: projects).path
            == (NSHomeDirectory() as NSString).appendingPathComponent("x"))
    }

    /// An item's `when:` mutes it, with its reason, once the check fails;
    /// items sharing one command run it once; the rest stay as they are.
    @Test
    func a_failing_item_check_mutes_its_items_and_each_command_runs_once() async throws {
        let (context, _, _) = try makeContext(files: ["ops.yaml": """
        name: Ops
        nodes:
          root:
            items:
              - { title: Pods, enter: root, when: &up { run: api-check, unavailable: API down } }
              - { title: Services, enter: root, when: *up }
              - { title: Contexts, enter: root }
              - { title: Logs, action: { copy: x }, when: { run: other-check } }
        """])
        let recorder = Recorder()
        recorder.outputs = ["api-check": Self.down, "other-check": Self.ok]
        let scope = CustomPaletteScope(
            target: CustomPaletteTarget(paletteID: "ops", node: "root", exports: [:], pill: PalettePill(title: "Ops", systemImage: "x")),
            runner: recorder.runner,
            conditionRunner: recorder.runner
        )
        scope.activate(context: context) {}
        let before = scope.sections(for: PaletteQuery(raw: ""), context: context).flatMap(\.items)
        let usableBefore = before.allSatisfy(\.isEnabled)
        #expect(usableBefore, "usable until a check says otherwise")
        await settle()

        let rows = scope.sections(for: PaletteQuery(raw: ""), context: context).flatMap(\.items)
        #expect(rows.map(\.title) == ["Pods", "Services", "Contexts", "Logs"])
        #expect(rows.map(\.isEnabled) == [false, false, true, true])
        #expect(rows[0].subtitle == "API down")
        #expect(recorder.calls.map(\.command).sorted() == ["api-check", "other-check"], "one run per command")
        #expect(recorder.calls.first?.cwd == "/tmp", "where a listing would run")

        // Told again when its frame returns to the top: nothing reruns. ⌘R does.
        scope.activate(context: context) {}
        #expect(recorder.calls.count == 2)
        recorder.outputs["api-check"] = Self.ok
        scope.retry()
        await settle()
        let usableAfter = scope.sections(for: PaletteQuery(raw: ""), context: context).flatMap(\.items).allSatisfy(\.isEnabled)
        #expect(usableAfter)
    }

    /// The palette's own `when:` gates its root: checked first, nothing
    /// shown meanwhile, the reason instead of a listing when it fails — and
    /// only on the root.
    @Test
    func a_palette_whose_check_fails_says_why_instead_of_listing() async throws {
        let (context, _, _) = try makeContext(files: ["k8s.yaml": """
        name: K8s
        when: { run: cluster-check, unavailable: Cluster unreachable }
        root: pods
        nodes:
          pods: { list: list-pods, action: { copy: . } }
          more: { list: list-more, action: { copy: . } }
        """])
        let recorder = Recorder()
        recorder.outputs = [
            "cluster-check": Self.down,
            "list-pods": CustomPaletteCommandResult(stdout: "api\nweb\n", stderr: "", status: 0),
        ]
        let root = CustomPaletteScope(
            target: CustomPaletteTarget(paletteID: "k8s", node: "pods", exports: [:], pill: PalettePill(title: "K8s", systemImage: "x")),
            runner: recorder.runner,
            conditionRunner: recorder.runner
        )
        root.activate(context: context) {}
        #expect(root.loading?.message == "Checking K8s…")
        #expect(root.sections(for: PaletteQuery(raw: ""), context: context).isEmpty)
        await settle()
        #expect(root.failure == PaletteFailure(title: "K8s isn't available", detail: "Cluster unreachable"))
        #expect(recorder.calls.map(\.command) == ["cluster-check"], "no listing behind a failed check")

        recorder.outputs["cluster-check"] = Self.ok
        root.retry()
        await settle()
        #expect(root.failure == nil)
        #expect(root.sections(for: PaletteQuery(raw: ""), context: context).flatMap(\.items).map(\.title) == ["api", "web"])

        // A deeper screen isn't gated again.
        recorder.outputs["list-more"] = CustomPaletteCommandResult(stdout: "x\n", stderr: "", status: 0)
        let deeper = CustomPaletteScope(
            target: CustomPaletteTarget(paletteID: "k8s", node: "more", exports: [:], pill: PalettePill(title: "More", systemImage: "x")),
            runner: recorder.runner,
            conditionRunner: recorder.runner
        )
        let checksSoFar = recorder.calls.count(where: { $0.command == "cluster-check" })
        deeper.activate(context: context) {}
        await settle()
        #expect(recorder.calls.count(where: { $0.command == "cluster-check" }) == checksSoFar)
        #expect(deeper.sections(for: PaletteQuery(raw: ""), context: context).flatMap(\.items).map(\.title) == ["x"])
    }

    /// The root list's palette rows: checked once per open, muted with the
    /// reason when the check fails, and forgotten when the palette closes.
    @Test
    func a_palette_row_is_muted_while_its_check_fails_and_checked_once_per_open() async throws {
        let (context, store, _) = try makeContext(files: ["k8s.yaml": """
        name: K8s
        description: Cluster screens
        when: { run: cluster-check, unavailable: Cluster unreachable }
        nodes: { root: { list: ls, action: { copy: . } } }
        """])
        let recorder = Recorder()
        recorder.outputs = ["cluster-check": Self.down]
        let availability = CustomPaletteAvailability(runner: recorder.runner)
        let palettes = store.entries.compactMap(\.palette)
        availability.check(palettes, context: context)
        availability.check(palettes, context: context)
        await settle()
        #expect(availability.unavailable == ["k8s": "Cluster unreachable"])
        #expect(recorder.calls.count == 1, "once per open")

        let row = { (unavailable: [String: String]) in
            CommandSource(unavailablePalettes: unavailable).emptyItems(context: context)?.first { $0.title == "K8s" }
        }
        #expect(row(availability.unavailable)?.isEnabled == false)
        #expect(row(availability.unavailable)?.subtitle == "Cluster unreachable")
        #expect(row(availability.unavailable)?.opensScope == nil, "nowhere to go: no chevron")
        #expect(row(availability.unavailable)?.icon == CustomPalette.defaultIcon, "its glyph, kept")
        #expect(row([:])?.opensScope != nil)
        #expect(row([:])?.isEnabled == true)
        #expect(row([:])?.subtitle == "Cluster screens")

        availability.reset()
        #expect(availability.unavailable.isEmpty)
        recorder.outputs["cluster-check"] = Self.ok
        availability.check(palettes, context: context)
        await settle()
        #expect(recorder.calls.count == 2, "checked again on the next open")
        #expect(availability.unavailable.isEmpty)
    }

    @Test
    func the_root_lists_extensions_under_palettes_and_broken_files_muted() throws {
        let (context, store, _) = try makeContext(files: [
            "kubernetes.yaml": CustomPaletteFileTests.kubernetes,
            "broken.yml": "name: Broken\nnodes: { root: { list: ls } }",
        ])
        let rows = { CommandSource().emptyItems(context: context) ?? [] }
        let palettes = rows().filter { $0.category == AppCommand.Category.palettes.rawValue }
        #expect(
            palettes.map(\.title) == ["Password Manager", "Worktrees", "Files", "Broken", "Kubernetes"],
            "custom palettes follow the built-in screens"
        )
        let kubernetes = try #require(palettes.first { $0.title == "Kubernetes" })
        #expect(try kubernetes.opensScope == .custom(#require(store.rootTarget(id: "kubernetes"))))
        #expect(kubernetes.icon == "shippingbox")
        #expect(kubernetes.subtitle == "Namespaces, pods and their logs", "a palette's description is its row's second line")
        let broken = try #require(palettes.first { $0.title == "Broken" })
        #expect(broken.isEnabled, "a broken file's row reads like any other")
        #expect(broken.warning == "root: needs enter: or action:")
        #expect(try broken.opensScope == .custom(#require(store.rootTarget(id: "broken"))))
        #expect(kubernetes.warning == nil)
    }
}
