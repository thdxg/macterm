import CoreGraphics
import Foundation
@testable import Macterm
import Testing

@MainActor
struct AppStateDesktopWidgetsTests {
    /// 7 columns × 4 rows; a centered medium widget lands at (376, 679).
    private static let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private static let medium = DesktopWidgetSize.medium.span

    /// A store on disk plus an AppState placing widgets on a fixed screen.
    private func makeFixture() throws -> (state: AppState, storeURL: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-widget-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appendingPathComponent("workspaces.json")
        return (makeState(storeURL: storeURL, dir: dir), storeURL, dir)
    }

    private func makeState(storeURL: URL, dir: URL, screens: [CGRect] = [screen], names: [String]? = nil) -> AppState {
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: storeURL),
            projectFiles: ProjectFileStore(directoryURL: dir.appendingPathComponent("projects", isDirectory: true)),
            quickTerminal: QuickTerminalSplitState()
        )
        let named = zip(screens, names ?? screens.indices.map { "Screen \($0 + 1)" })
            .map { DesktopScreen(name: $1, visibleFrame: $0) }
        state.desktopScreens = { named }
        // A listing that fails reattaches every restored widget — the
        // default here, so no test respawns a session it didn't ask to.
        var zmx = recordingZmx(into: WidgetKills())
        zmx.listSessionsWithClients = { nil }
        state.zmx = zmx
        return state
    }

    private func recordingZmx(into killed: WidgetKills) -> ZmxClient {
        ZmxClient(
            executableURL: { nil },
            isBundled: { true },
            killSession: { name in await killed.append(name) },
            killRemoteSession: { _, name, _ in await killed.append(name) },
            remoteForegrounds: { _, _ in .unreachable },
            sweepRemoteOrphans: { _, _, _, _ in nil },
            listSessionsWithClients: { [] },
            sessionLeaderPIDs: { [:] },
            sessionListSnapshot: { (entries: [], leaders: [:]) }
        )
    }

    private func savedWidgets(_ storeURL: URL) -> [DesktopWidgetSnapshot] {
        WorkspaceStore(fileURL: storeURL).load().desktopWidgets
    }

    // MARK: - Create

    /// A new widget is durable the moment it exists — a crash must not orphan
    /// the shell the user just placed on the desktop — and it starts locked
    /// in the middle of the screen.
    @Test
    func a_new_widget_is_locked_centered_and_persisted_at_once() throws {
        let (state, storeURL, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        state.restoreSelection(projects: [])

        let widget = state.createDesktopWidget(span: Self.medium, command: "htop")

        #expect(state.editingDesktopWidgetID == nil)
        #expect(widget.topLeft == CGPoint(x: 376, y: 679))
        let saved = try #require(savedWidgets(storeURL).first)
        #expect(saved.id == widget.id)
        #expect((saved.columns, saved.rows) == (2, 1))
        #expect(saved.command == "htop")
        #expect(CGPoint(x: saved.topLeftX, y: saved.topLeftY) == widget.topLeft)
        let restored = WorkspaceSerializer.restoreTab(saved.tab, projectID: DesktopWidget.projectID)
        #expect(restored.splitRoot.allPanes().map(\.sessionName) == [widget.pane?.sessionName])
    }

    @Test
    func new_widgets_take_free_cells_rather_than_stacking() throws {
        let (state, _, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = state.createDesktopWidget(span: Self.medium)
        let second = state.createDesktopWidget(span: Self.medium)
        #expect(!first.frame.insetBy(dx: 1, dy: 1).intersects(second.frame))
    }

    @Test
    func a_widget_created_without_a_size_takes_the_default_size() throws {
        let (state, _, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let widget = state.createDesktopWidget()
        #expect(widget.span == Preferences.shared.desktopWidgetDefaultSize.span)
    }

    /// Until the launch restore has run, `workspaces` is empty — a save then
    /// would write that emptiness over the file about to be restored.
    @Test
    func a_widget_created_before_the_launch_restore_saves_nothing() throws {
        let (state, storeURL, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sentinel = #"{"version": 6, "workspaces": [], "pinned": [], "windows": []}"#
        try sentinel.write(to: storeURL, atomically: true, encoding: .utf8)

        state.createDesktopWidget()

        #expect(try String(contentsOf: storeURL, encoding: .utf8) == sentinel)
    }

    // MARK: - Editing

    /// One widget at a time: the edited one has to be locked before another
    /// can be unlocked.
    @Test
    func only_one_widget_can_be_edited_at_a_time() throws {
        let (state, _, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = state.createDesktopWidget()
        let second = state.createDesktopWidget()

        #expect(state.beginEditingDesktopWidget(id: first.id))
        #expect(state.editingDesktopWidgetID == first.id)
        #expect(!state.canEditDesktopWidget(id: second.id))
        #expect(!state.beginEditingDesktopWidget(id: second.id))
        #expect(state.editingDesktopWidgetID == first.id)

        state.endEditingDesktopWidget()
        #expect(state.editingDesktopWidgetID == nil)
        #expect(state.beginEditingDesktopWidget(id: second.id))
        #expect(state.editingDesktopWidgetID == second.id)
    }

    @Test
    func removing_the_edited_widget_frees_the_edit_slot() throws {
        let (state, _, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let widget = state.createDesktopWidget()
        state.beginEditingDesktopWidget(id: widget.id)
        state.removeDesktopWidget(id: widget.id)
        #expect(state.editingDesktopWidgetID == nil)
    }

    // MARK: - Geometry

    /// Letting go of a drag or a resize settles the widget on the grid, and
    /// that is what persists.
    @Test
    func a_dropped_or_resized_widget_settles_on_the_grid_and_persists() throws {
        let (state, storeURL, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        state.restoreSelection(projects: [])
        let widget = state.createDesktopWidget(span: Self.medium)

        state.settleDesktopWidget(id: widget.id, frame: CGRect(x: 30, y: 500, width: 530, height: 345))

        #expect(widget.span == DesktopWidgetSpan(columns: 3, rows: 2))
        #expect(widget.topLeft == CGPoint(x: 16, y: 859))
        let saved = try #require(savedWidgets(storeURL).first)
        #expect((saved.columns, saved.rows) == (3, 2))
        #expect(CGPoint(x: saved.topLeftX, y: saved.topLeftY) == CGPoint(x: 16, y: 859))
    }

    /// A widget settles around its neighbours, never onto them — but its own
    /// old frame is no obstacle.
    @Test
    func a_widget_settles_around_its_neighbours_but_not_around_itself() throws {
        let (state, _, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let still = state.createDesktopWidget(span: Self.medium)
        let moving = state.createDesktopWidget(span: Self.medium)

        state.settleDesktopWidget(id: moving.id, frame: moving.frame)
        #expect(moving.topLeft == CGPoint(x: 376, y: 859))

        state.settleDesktopWidget(id: moving.id, frame: still.frame)
        #expect(!moving.frame.insetBy(dx: 1, dy: 1).intersects(still.frame))
    }

    @Test
    func picking_a_size_keeps_the_top_left_corner() throws {
        let (state, _, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let widget = state.createDesktopWidget(span: DesktopWidgetSize.small.span)
        let corner = widget.topLeft
        state.setDesktopWidgetSpan(DesktopWidgetSize.large.span, id: widget.id)
        #expect(widget.span == DesktopWidgetSize.large.span)
        #expect(widget.topLeft == corner)
    }

    // MARK: - Restore

    /// Launch hands every widget back as it was — same id, span, spot and
    /// command, and the same session name, which is what reattaches it — and
    /// every one locked, whatever was being edited at quit.
    @Test
    func restoreSelection_hands_the_widgets_back_locked() throws {
        let (writer, storeURL, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        writer.restoreSelection(projects: [])
        let first = writer.createDesktopWidget(span: DesktopWidgetSize.small.span, command: "top")
        let second = writer.createDesktopWidget(span: DesktopWidgetSpan(columns: 3, rows: 2))
        writer.beginEditingDesktopWidget(id: second.id)

        let state = makeState(storeURL: storeURL, dir: dir)
        state.restoreSelection(projects: [])

        #expect(state.desktopWidgets.map(\.id) == [first.id, second.id])
        #expect(state.editingDesktopWidgetID == nil)
        let restoredFirst = try #require(state.desktopWidget(id: first.id))
        #expect(restoredFirst.span == DesktopWidgetSize.small.span)
        #expect(restoredFirst.command == "top")
        #expect(restoredFirst.topLeft == first.topLeft)
        #expect(restoredFirst.pane?.sessionName == first.pane?.sessionName)
        #expect(restoredFirst.pane?.projectID == DesktopWidget.projectID)
        #expect(state.desktopWidget(id: second.id)?.span == DesktopWidgetSpan(columns: 3, rows: 2))
    }

    /// A widget saved on a display that has since gone away is placed afresh
    /// on a screen that exists, not restored where nobody can reach it.
    @Test
    func a_widget_whose_display_is_gone_is_placed_on_a_screen_that_exists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-widget-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("workspaces.json")
        let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let writer = makeState(storeURL: storeURL, dir: dir, screens: [external])
        writer.restoreSelection(projects: [])
        let widget = writer.createDesktopWidget(span: Self.medium)
        #expect(widget.frame.minX > 1440)

        let state = makeState(storeURL: storeURL, dir: dir, screens: [Self.screen])
        state.restoreSelection(projects: [])

        let restored = try #require(state.desktopWidget(id: widget.id))
        #expect(DesktopWidgetGrid.isReachable(restored.frame, on: [Self.screen]))
    }

    /// The launch sweep kills zero-client sessions nobody claims. A restored
    /// widget attaches only once its window builds a surface, so its session
    /// is zero-client at exactly that moment and must count as claimed.
    @Test
    func the_launch_sweep_spares_restored_widget_sessions() async throws {
        let (writer, storeURL, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        writer.restoreSelection(projects: [])
        let widget = writer.createDesktopWidget()
        let widgetSession = try #require(widget.pane?.sessionName)

        let orphan = "macterm-widget-0123456789ab"
        let killed = WidgetKills()
        var zmx = recordingZmx(into: killed)
        zmx.listSessionsWithClients = {
            [widgetSession, orphan].map { ZmxSessionListParser.Entry(name: $0, clients: 0, owner: nil) }
        }
        let state = makeState(storeURL: storeURL, dir: dir)
        state.zmx = zmx
        state.restoreSelection(projects: [])

        await killed.settle(expecting: 1)
        #expect(await killed.names == [orphan])
    }

    // MARK: - Remove / exit

    @Test
    func removing_a_widget_kills_its_session_and_forgets_it() async throws {
        let (state, storeURL, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let killed = WidgetKills()
        state.zmx = recordingZmx(into: killed)
        state.restoreSelection(projects: [])
        let keep = state.createDesktopWidget()
        let gone = state.createDesktopWidget()
        let goneSession = try #require(gone.pane?.sessionName)

        state.removeDesktopWidget(id: gone.id)

        await killed.settle(expecting: 1)
        #expect(await killed.names == [goneSession])
        #expect(state.desktopWidgets.map(\.id) == [keep.id])
        #expect(savedWidgets(storeURL).map(\.id) == [keep.id])
    }

    /// A widget always holds a terminal: when its shell exits it starts over
    /// in a new session (the old one is disposed of) instead of closing.
    @Test
    func a_widget_whose_shell_exits_starts_over_in_a_new_session() async throws {
        let (state, storeURL, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let killed = WidgetKills()
        state.zmx = recordingZmx(into: killed)
        state.restoreSelection(projects: [])
        let widget = state.createDesktopWidget(command: "htop")
        let oldSession = try #require(widget.pane?.sessionName)

        state.desktopWidgetShellExited(id: widget.id)

        await killed.settle(expecting: 1)
        #expect(await killed.names == [oldSession])
        let newSession = try #require(widget.pane?.sessionName)
        #expect(newSession != oldSession)
        #expect(widget.pane?.command == "htop")
        let saved = try #require(savedWidgets(storeURL).first)
        let restored = WorkspaceSerializer.restoreTab(saved.tab, projectID: DesktopWidget.projectID)
        #expect(restored.splitRoot.allPanes().map(\.sessionName) == [newSession])
    }

    /// The presenter follows every change, so the desktop always matches the
    /// model.
    @Test
    func the_presenter_sees_every_change() throws {
        let (state, _, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let presenter = RecordingPresenter()
        state.attachDesktopWidgetPresenter(presenter)
        let widget = state.createDesktopWidget()
        state.beginEditingDesktopWidget(id: widget.id)
        state.endEditingDesktopWidget()
        state.removeDesktopWidget(id: widget.id)
        #expect(presenter.syncs == [
            .init(ids: [], editing: nil),
            .init(ids: [widget.id], editing: nil),
            .init(ids: [widget.id], editing: widget.id),
            .init(ids: [widget.id], editing: nil),
            .init(ids: [], editing: nil),
        ])
    }
}

extension AppStateDesktopWidgetsTests {
    private func layoutFile(_ dir: URL) -> URL {
        dir.appendingPathComponent("widgets/widgets.yaml")
    }

    private func writeLayout(_ yaml: String, in dir: URL) throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("widgets", isDirectory: true),
            withIntermediateDirectories: true
        )
        try yaml.write(to: layoutFile(dir), atomically: true, encoding: .utf8)
    }

    private func declared(_ dir: URL) throws -> [WidgetDeclaration] {
        try WidgetLayoutFile.parse(yaml: String(contentsOf: layoutFile(dir), encoding: .utf8)).widgets ?? []
    }

    // MARK: - widgets.yaml

    /// The file follows every change: it declares each widget's size, grid
    /// cell and recipe, and the primary display goes unnamed.
    @Test
    func widgets_yaml_declares_every_widget_after_a_change() throws {
        let (state, _, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        state.restoreSelection(projects: [])
        state.createDesktopWidget(span: Self.medium, name: "logs", command: "tail -f log")

        let entries = try declared(dir)
        #expect(entries == [WidgetDeclaration(
            name: "logs", size: "medium", column: 2, row: 1, display: nil, cwd: nil, run: "tail -f log"
        )])
        let text = try String(contentsOf: layoutFile(dir), encoding: .utf8)
        #expect(text.contains(WidgetLayoutFile.schemaModeline))
    }

    @Test
    func a_widget_on_another_display_names_it() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-widget-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let state = makeState(
            storeURL: dir.appendingPathComponent("workspaces.json"),
            dir: dir,
            screens: [Self.screen, external],
            names: ["Built-in", "Studio Display"]
        )
        state.restoreSelection(projects: [])
        let widget = state.createDesktopWidget(span: DesktopWidgetSize.small.span)
        state.settleDesktopWidget(id: widget.id, frame: DesktopWidgetGrid.frame(
            topLeft: DesktopWidgetGrid.topLeft(column: 1, row: 2, in: external),
            span: widget.span
        ))

        let entry = try #require(try declared(dir).first)
        #expect(entry.display == "Studio Display")
        #expect((entry.column, entry.row) == (1, 2))
    }

    /// Nobody who never had a widget gets a file.
    @Test
    func no_file_is_written_without_widgets() throws {
        let (state, _, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        state.restoreSelection(projects: [])
        state.persistForTermination()
        #expect(!FileManager.default.fileExists(atPath: layoutFile(dir).path))
    }

    /// At launch the file decides: an entry added by hand becomes a widget
    /// running its recipe in its cell, an entry removed takes its widget
    /// (and session) with it, and an edited entry resizes and moves its
    /// widget while it keeps its session.
    @Test
    func the_file_decides_membership_and_geometry_at_launch() async throws {
        let (writer, storeURL, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        writer.restoreSelection(projects: [])
        let kept = writer.createDesktopWidget(span: Self.medium, name: "kept")
        let dropped = writer.createDesktopWidget(span: Self.medium, name: "dropped")
        let droppedSession = try #require(dropped.pane?.sessionName)
        try writeLayout("""
        widgets:
          - name: kept
            size: large
            column: 0
            row: 0
          - name: added
            size: small
            column: 5
            row: 2
            run: htop
        """, in: dir)

        let killed = WidgetKills()
        let state = makeState(storeURL: storeURL, dir: dir)
        var zmx = recordingZmx(into: killed)
        zmx.listSessionsWithClients = { nil }
        state.zmx = zmx
        state.restoreSelection(projects: [])

        #expect(state.desktopWidgets.map(\.name) == ["kept", "added"])
        let restoredKept = try #require(state.desktopWidget(id: kept.id))
        #expect(restoredKept.pane?.sessionName == kept.pane?.sessionName)
        #expect(restoredKept.span == DesktopWidgetSize.large.span)
        #expect(restoredKept.topLeft == DesktopWidgetGrid.topLeft(column: 0, row: 0, in: Self.screen))
        let added = try #require(state.desktopWidgets.last)
        #expect(added.span == DesktopWidgetSize.small.span)
        #expect(added.topLeft == DesktopWidgetGrid.topLeft(column: 5, row: 2, in: Self.screen))
        #expect(added.pane?.command == "htop")
        await killed.settle(expecting: 1)
        #expect(await killed.names.contains(droppedSession))
    }

    /// An absent file is "no input", never "remove every widget".
    @Test
    func an_absent_file_removes_nothing_and_is_rewritten() throws {
        let (writer, storeURL, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        writer.restoreSelection(projects: [])
        let widget = writer.createDesktopWidget()
        try FileManager.default.removeItem(at: layoutFile(dir))

        let state = makeState(storeURL: storeURL, dir: dir)
        state.restoreSelection(projects: [])

        #expect(state.desktopWidgets.map(\.id) == [widget.id])
        #expect(try declared(dir).count == 1)
    }

    /// A file edited while Macterm runs is absorbed before Macterm's next
    /// write: an edit applies, and removing a live widget's entry does not
    /// kill it mid-session (that waits for the next launch).
    @Test
    func an_external_edit_is_absorbed_before_the_next_write() throws {
        let (state, _, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        state.restoreSelection(projects: [])
        let resized = state.createDesktopWidget(span: Self.medium, name: "resized")
        let unlisted = state.createDesktopWidget(span: Self.medium, name: "unlisted")
        try writeLayout("""
        widgets:
          - name: resized
            size: extra-large
            column: 0
            row: 0
        """, in: dir)

        state.createDesktopWidget(span: DesktopWidgetSize.small.span, name: "third")

        #expect(resized.span == DesktopWidgetSize.extraLarge.span)
        #expect(state.desktopWidget(id: unlisted.id) != nil)
        #expect(try declared(dir).map(\.name) == ["resized", "unlisted", "third"])
    }

    /// A file that doesn't parse is the user mid-edit: nothing is written
    /// over it until it parses again.
    @Test
    func an_unparseable_file_is_never_overwritten() throws {
        let (state, _, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        state.restoreSelection(projects: [])
        state.createDesktopWidget()
        let broken = "widgets:\n  - size: [unclosed\n"
        try writeLayout(broken, in: dir)

        state.createDesktopWidget()

        #expect(try String(contentsOf: layoutFile(dir), encoding: .utf8) == broken)
        #expect(state.widgetLayoutSuspended)
    }

    // MARK: - Respawn

    /// A restored widget whose session didn't survive (a reboot) respawns
    /// from its recipe — and is drawn only once that has been decided.
    @Test
    func a_widget_whose_session_is_gone_respawns_from_its_recipe() async throws {
        let (writer, storeURL, dir) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        writer.restoreSelection(projects: [])
        let survivor = writer.createDesktopWidget(name: "survivor")
        let lost = writer.createDesktopWidget(name: "lost", command: "htop")
        let survivorSession = try #require(survivor.pane?.sessionName)
        let lostSession = try #require(lost.pane?.sessionName)

        let state = makeState(storeURL: storeURL, dir: dir)
        var zmx = recordingZmx(into: WidgetKills())
        zmx.listSessionsWithClients = { [ZmxSessionListParser.Entry(name: survivorSession, clients: 0, owner: nil)] }
        state.zmx = zmx
        let presenter = RecordingPresenter()
        state.attachDesktopWidgetPresenter(presenter)
        let restored = state.restoreDesktopWidgets(WorkspaceStore(fileURL: storeURL).load().desktopWidgets)
        #expect(presenter.syncs.last?.ids.isEmpty == true)

        await state.materializeRestoredDesktopWidgets(restored)

        #expect(state.desktopWidget(id: survivor.id)?.pane?.sessionName == survivorSession)
        let respawned = try #require(state.desktopWidget(id: lost.id)?.pane)
        #expect(respawned.sessionName != lostSession)
        #expect(respawned.command == "htop")
        #expect(presenter.syncs.last?.ids == [survivor.id, lost.id])
    }

    @Test
    func entries_match_by_name_then_content_then_position() {
        let current = [
            WidgetDeclaration(name: "a", size: "small"),
            WidgetDeclaration(size: "large", column: 1, row: 1),
            WidgetDeclaration(size: "medium"),
        ]
        let entries = [
            WidgetDeclaration(size: "large", column: 1, row: 1),
            WidgetDeclaration(name: "a", size: "medium"),
            WidgetDeclaration(size: "small"),
            WidgetDeclaration(name: "new"),
        ]
        let matching = WidgetLayoutMatcher.match(entries: entries, current: current)
        #expect(matching.pairs.map(\.widget) == [1, 0, 2, nil])
        #expect(matching.removed.isEmpty)
    }
}

@MainActor
private final class RecordingPresenter: DesktopWidgetPresenting {
    struct Sync: Equatable {
        let ids: [UUID]
        let editing: UUID?
    }

    var syncs: [Sync] = []
    func sync(_ widgets: [DesktopWidget], editing: UUID?) {
        syncs.append(Sync(ids: widgets.map(\.id), editing: editing))
    }
}

/// Session names killed across the fire-and-forget kill tasks.
private actor WidgetKills {
    private(set) var names: Set<String> = []

    func append(_ name: String) {
        names.insert(name)
    }

    func settle(expecting count: Int) async {
        for _ in 0 ..< 200 where names.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
