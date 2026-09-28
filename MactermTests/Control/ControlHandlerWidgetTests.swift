import CoreGraphics
import Foundation
@testable import Macterm
import Testing

@MainActor
struct ControlHandlerWidgetTests {
    private func makeHandler() -> (ControlHandler, AppState) {
        let tmp = FileManager.default.temporaryDirectory
        let appState = AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp.appendingPathComponent("macterm-widget-control-\(UUID().uuidString).json")),
            projectFiles: ProjectFileStore(directoryURL: tmp.appendingPathComponent(
                "macterm-widget-control-projects-\(UUID().uuidString)",
                isDirectory: true
            )),
            quickTerminal: QuickTerminalSplitState()
        )
        appState.desktopScreens = { [DesktopScreen(name: "Test", visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))] }
        appState.nativeDesktopWidgetFrames = { [] }
        let store = ProjectStore(fileURL: tmp.appendingPathComponent("macterm-widget-control-store-\(UUID().uuidString).json"))
        return (ControlHandler(appState: appState, projectStore: store), appState)
    }

    private func widgetArgs(_ widget: String? = nil, size: String? = nil, run: String? = nil) -> ControlArgs {
        var args = ControlArgs(run: run)
        args.widget = widget
        args.size = size
        return args
    }

    @Test
    func widget_new_adds_a_locked_three_by_three_widget() async throws {
        let (handler, state) = makeHandler()
        let response = await handler.handle(ControlRequest(command: "widget.new", args: widgetArgs()))
        #expect(response.ok)
        let info = try #require(response.data?.widgets?.first)
        #expect(info.index == 1)
        #expect(info.size == "3x3")
        #expect(!info.editing)
        #expect(info.command == nil)
        #expect(info.session == state.desktopWidgets.first?.pane?.sessionName)
    }

    @Test
    func widget_new_takes_a_span_and_a_command() async throws {
        let (handler, state) = makeHandler()
        let response = await handler.handle(ControlRequest(command: "widget.new", args: widgetArgs(size: "4x2", run: "htop")))
        let info = try #require(response.data?.widgets?.first)
        #expect(info.size == "4x2")
        #expect((info.columns, info.rows) == (4, 2))
        #expect(info.command == "htop")
        #expect(state.desktopWidgets.first?.pane?.command == "htop")
    }

    @Test
    func a_size_that_is_not_a_span_is_a_bad_request() async {
        let (handler, state) = makeHandler()
        // The retired family names included.
        for size in ["huge", "large"] {
            let response = await handler.handle(ControlRequest(command: "widget.new", args: widgetArgs(size: size)))
            #expect(response.error?.code == .badRequest)
            #expect(response.error?.message.contains("COLUMNSxROWS") == true)
        }
        #expect(state.desktopWidgets.isEmpty)
    }

    @Test
    func widget_list_reports_every_widget_in_creation_order() async {
        let (handler, state) = makeHandler()
        let first = state.createDesktopWidget(span: DesktopWidgetSpan.small)
        let second = state.createDesktopWidget(span: DesktopWidgetSpan.large)
        state.beginEditingDesktopWidget(id: second.id)
        let response = await handler.handle(ControlRequest(command: "widget.list"))
        #expect(response.data?.widgets?.map(\.id) == [first.id.uuidString, second.id.uuidString])
        #expect(response.data?.widgets?.map(\.index) == [1, 2])
        #expect(response.data?.widgets?.map(\.editing) == [false, true])
    }

    /// `set` resolves by index, `widget:N` or id.
    @Test
    func widget_set_resizes_by_any_selector() async {
        let (handler, state) = makeHandler()
        state.createDesktopWidget(span: DesktopWidgetSpan.small)
        let widget = state.createDesktopWidget(span: DesktopWidgetSpan.small)

        _ = await handler.handle(ControlRequest(command: "widget.set", args: widgetArgs("widget:2", size: "2x2")))
        #expect(widget.span == DesktopWidgetSpan.large)
        _ = await handler.handle(ControlRequest(command: "widget.set", args: widgetArgs(widget.id.uuidString, size: "2x1")))
        #expect(widget.span == DesktopWidgetSpan.medium)
        let response = await handler.handle(ControlRequest(command: "widget.set", args: widgetArgs("2", size: "1x1")))
        #expect(widget.span == DesktopWidgetSpan.small)
        #expect(response.data?.widgets?.first?.index == 2)
    }

    /// `edit` is refused with `busy` while another widget is being edited,
    /// and `done` locks it.
    @Test
    func widget_edit_is_one_at_a_time_and_done_locks_it() async {
        let (handler, state) = makeHandler()
        let first = state.createDesktopWidget()
        state.createDesktopWidget()

        let edit = await handler.handle(ControlRequest(command: "widget.edit", args: widgetArgs("1")))
        #expect(edit.data?.widgets?.first?.editing == true)
        #expect(state.editingDesktopWidgetID == first.id)

        let refused = await handler.handle(ControlRequest(command: "widget.edit", args: widgetArgs("2")))
        #expect(refused.error?.code == .busy)
        #expect(state.editingDesktopWidgetID == first.id)

        let done = await handler.handle(ControlRequest(command: "widget.done"))
        #expect(done.ok)
        #expect(state.editingDesktopWidgetID == nil)
    }

    @Test
    func a_widget_selector_that_matches_nothing_is_not_found() async {
        let (handler, state) = makeHandler()
        state.createDesktopWidget()
        let response = await handler.handle(ControlRequest(command: "widget.remove", args: widgetArgs("widget:5")))
        #expect(response.error?.code == .notFound)
        #expect(state.desktopWidgets.count == 1)
    }

    @Test
    func widget_remove_removes_it() async {
        let (handler, state) = makeHandler()
        let widget = state.createDesktopWidget()
        let response = await handler.handle(ControlRequest(command: "widget.remove", args: widgetArgs("1")))
        #expect(response.ok)
        #expect(state.desktopWidget(id: widget.id) == nil)
    }

    /// Widgets are outside every workspace, so the pane verbs reach a
    /// widget's pane by its session name — here it has no surface yet (no
    /// window in a unit test), which is the typed miss, not a not-found.
    @Test
    func pane_verbs_reach_a_widget_pane_by_its_session() async throws {
        let (handler, state) = makeHandler()
        let widget = state.createDesktopWidget()
        let session = try #require(widget.pane?.sessionName)
        for command in ["pane.dump", "pane.inspect"] {
            let response = await handler.handle(ControlRequest(command: command, args: ControlArgs(session: session)))
            #expect(response.error?.code == .noSurface, "\(command)")
        }
        let run = await handler.handle(ControlRequest(command: "pane.run", args: ControlArgs(session: session, run: "ls")))
        #expect(run.error?.code == .noSurface)
        var key = ControlArgs(session: session)
        key.key = "ctrl+c"
        let keyResponse = await handler.handle(ControlRequest(command: "pane.key", args: key))
        #expect(keyResponse.error?.code == .noSurface)
    }
}

/// The system's widget families, as spans — what these tests size widgets by.
private extension DesktopWidgetSpan {
    static let small = DesktopWidgetSpan(columns: 1, rows: 1)
    static let medium = DesktopWidgetSpan(columns: 2, rows: 1)
    static let large = DesktopWidgetSpan(columns: 2, rows: 2)
    static let extraLarge = DesktopWidgetSpan(columns: 4, rows: 2)
}
