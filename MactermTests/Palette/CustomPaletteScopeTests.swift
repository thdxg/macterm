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
    /// was asked, including the environment.
    private final class Recorder: @unchecked Sendable {
        var calls: [(command: String, environment: [String: String], cwd: String?)] = []
        var outputs: [String: CustomPaletteCommandResult] = [:]
        var runner: CustomPaletteCommandRunner {
            { [self] command, environment, cwd in
                calls.append((command, environment, cwd))
                return outputs[command] ?? CustomPaletteCommandResult(stdout: "", stderr: "no canned output for \(command)", status: 1)
            }
        }
    }

    private func settle() async {
        for _ in 0 ..< 50 {
            try? await Task.sleep(for: .milliseconds(10))
        }
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
    func the_root_lists_custom_palettes_under_palettes_hidden_when_off_and_broken_files_muted() throws {
        let (context, store, _) = try makeContext(files: [
            "kubernetes.yaml": CustomPaletteFileTests.kubernetes,
            "broken.yml": "name: Broken\nnodes: { root: { list: ls } }",
        ])
        let prior = Preferences.shared.disabledPaletteIDs
        defer { Preferences.shared.disabledPaletteIDs = prior }

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

        Preferences.shared.setPalette(PaletteScopeID.customSettingsID(paletteID: "kubernetes"), enabled: false)
        #expect(!rows().contains { $0.title == "Kubernetes" })
        #expect(try !PaletteScopeID.custom(#require(store.rootTarget(id: "kubernetes"))).isEnabled)
    }
}
