import Foundation
@testable import Macterm
import Testing

@MainActor
struct PinnedLayoutStoreTests {
    private func makeStore() -> (store: PinnedLayoutStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-pinned-\(UUID().uuidString)", isDirectory: true)
        return (PinnedLayoutStore(directoryURL: dir), dir)
    }

    @Test
    func read_absent_file() {
        let (store, _) = makeStore()
        guard case .absent = store.read() else {
            Issue.record("expected .absent")
            return
        }
    }

    @Test
    func read_empty_file_is_absent_not_remove_everything() throws {
        // An editor's truncate-then-write save can expose a momentarily empty
        // file; reading it as "zero pinned tabs" would unpin the whole set.
        let (store, dir) = makeStore()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "  \n".write(to: store.fileURL, atomically: true, encoding: .utf8)
        guard case .absent = store.read() else {
            Issue.record("expected .absent for an empty file")
            return
        }
    }

    @Test
    func write_then_read_round_trips_tabs_and_marker() throws {
        let (store, _) = makeStore()
        let id = UUID()
        let tabs = [LayoutTab(
            id: id,
            name: "dev server",
            layout: .split(LayoutBranch(
                direction: .horizontal,
                ratio: 0.6,
                first: .pane(LayoutPane(cwd: "~/dev/api", run: "npm run dev")),
                second: .pane(LayoutPane(cwd: "~/dev/api"))
            ))
        )]

        try store.write(tabs: tabs)

        guard case let .file(file, text) = store.read() else {
            Issue.record("expected .file")
            return
        }
        #expect(file.pinned == true)
        #expect(file.tabs == tabs)
        #expect(text.contains(id.uuidString))
    }

    @Test
    func read_unparseable_yaml_is_invalid() throws {
        let (store, dir) = makeStore()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "pinned: true\ntabs: [ {{".write(to: store.fileURL, atomically: true, encoding: .utf8)
        guard case .invalid = store.read() else {
            Issue.record("expected .invalid")
            return
        }
    }

    @Test
    func read_file_without_marker_is_invalid() throws {
        // A foreign file squatting on the name (e.g. a hand-crafted project
        // file) must never be treated — or overwritten — as ours.
        let (store, dir) = makeStore()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "path: ~/dev\ntabs:\n  - run: btop\n".write(to: store.fileURL, atomically: true, encoding: .utf8)
        guard case .invalid = store.read() else {
            Issue.record("expected .invalid without the pinned marker")
            return
        }
    }

    // MARK: - Project-file machinery keeps its hands off

    @Test
    func projectFileStore_listAll_excludes_pinned_yaml() throws {
        let (store, dir) = makeStore()
        try store.write(tabs: [])
        let projectFiles = ProjectFileStore(directoryURL: dir)
        try projectFiles.write(
            ProjectFile(name: "api", path: "/tmp/api", zmxPath: nil, tabs: nil),
            projectName: "api"
        )

        let listed = projectFiles.listAll().map(\.filename)

        #expect(listed == ["api.yaml"])
    }

    @Test
    func project_named_pinned_never_claims_pinned_yaml() throws {
        // Even before pinned.yaml exists: the name is reserved outright, so
        // the collision suffix kicks in.
        let (_, dir) = makeStore()
        let projectFiles = ProjectFileStore(directoryURL: dir)

        let target = try projectFiles.write(
            ProjectFile(name: "Pinned", path: "/tmp/whatever", zmxPath: nil, tabs: nil),
            projectName: "Pinned"
        )

        #expect(target.lastPathComponent == "pinned_2.yaml")
    }

    @Test
    func save_layout_never_realign_deletes_pinned_yaml() throws {
        // A hand-crafted pinned.yaml carrying a path: must not be bound (and
        // realign-deleted) by a project save declaring the same path.
        let (store, dir) = makeStore()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "pinned: true\npath: /tmp/api\ntabs:\n".write(to: store.fileURL, atomically: true, encoding: .utf8)
        let projectFiles = ProjectFileStore(directoryURL: dir)

        let target = try projectFiles.write(
            ProjectFile(name: "api", path: "/tmp/api", zmxPath: nil, tabs: nil),
            projectName: "api"
        )

        #expect(target.lastPathComponent == "api.yaml")
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    // MARK: - Declaration capture

    @Test
    func pinnedDeclaration_captures_run_and_absolute_cwd() {
        let (tree, ids) = build(H(pane("a", projectPath: "/tmp/api"), pane("b", projectPath: "/tmp/api/sub")))
        let tab = TerminalTab(id: UUID(), splitRoot: tree, focusedPaneID: ids["a"], customTitle: "dev")
        let recordID = UUID()

        let declaration = LayoutSerializer.pinnedDeclaration(
            for: tab,
            id: recordID,
            liveCommand: { $0.id == ids["a"] ? "npm run dev" : nil },
            liveShell: { _ in nil }
        )

        #expect(declaration.id == recordID)
        #expect(declaration.name == "dev")
        guard case let .split(branch) = declaration.layout,
              case let .pane(first) = branch.first,
              case let .pane(second) = branch.second
        else {
            Issue.record("expected a split of two leaves")
            return
        }
        #expect(first.cwd == "/tmp/api")
        #expect(first.run == "npm run dev")
        #expect(second.cwd == "/tmp/api/sub")
        #expect(second.run == nil)
    }

    @Test
    func pinnedDeclaration_contracts_home_and_keeps_remote_specs_verbatim() {
        let home = ProjectPath.currentHome
        let (tree, _) = build(H(
            pane("local", projectPath: home + "/dev/api"),
            pane("remote", projectPath: "devbox:~/work")
        ))
        let tab = TerminalTab(id: UUID(), splitRoot: tree, focusedPaneID: nil)

        let declaration = LayoutSerializer.pinnedDeclaration(
            for: tab,
            id: UUID(),
            liveCommand: { _ in nil },
            liveShell: { _ in nil }
        )

        guard case let .split(branch) = declaration.layout,
              case let .pane(local) = branch.first,
              case let .pane(remote) = branch.second
        else {
            Issue.record("expected a split of two leaves")
            return
        }
        #expect(local.cwd == "~/dev/api")
        #expect(remote.cwd == "devbox:~/work")
        // Round trip: both resolve back to full self-contained paths.
        #expect(LayoutBuilder.resolveCwd(local.cwd, projectRoot: PinnedTabs.fallbackRoot) == home + "/dev/api")
        #expect(LayoutBuilder.resolveCwd(remote.cwd, projectRoot: PinnedTabs.fallbackRoot) == "devbox:~/work")
    }

    // MARK: - Snapshot round trip

    @Test
    func pinned_snapshots_round_trip_through_the_store() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = WorkspaceStore(fileURL: tmp)

        let ws = Workspace(projectID: PinnedTabs.projectID, projectPath: "/tmp")
        let liveTab = ws.tabs[0]
        let records = [
            PinnedTabRecord(
                id: liveTab.id,
                declaration: LayoutTab(id: liveTab.id, layout: .pane(LayoutPane(cwd: "/tmp"))),
                originProjectID: UUID()
            ),
            PinnedTabRecord(
                id: UUID(),
                declaration: LayoutTab(name: "unloaded", layout: .pane(LayoutPane(run: "btop"))),
                originProjectID: nil
            ),
        ]

        store.save([], pinned: WorkspaceSerializer.snapshotPinned(records: records, workspace: ws))
        let loaded = WorkspaceStore(fileURL: tmp).load()

        #expect(loaded.pinned.count == 2)
        #expect(loaded.pinned[0].live?.id == liveTab.id)
        #expect(loaded.pinned[0].originProjectID == records[0].originProjectID)
        #expect(loaded.pinned[1].live == nil)
        #expect(loaded.pinned[1].declaration == records[1].declaration)
    }

    @Test
    func v4_file_without_pinned_section_loads_with_empty_pinned() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let json = """
        { "version": 4, "workspaces": [] }
        """
        try Data(json.utf8).write(to: tmp)

        let loaded = WorkspaceStore(fileURL: tmp).load()

        #expect(loaded.workspaces.isEmpty)
        #expect(loaded.pinned.isEmpty)
    }
}
