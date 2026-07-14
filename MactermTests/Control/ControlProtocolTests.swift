import Foundation
@testable import Macterm
import Testing

struct ControlProtocolTests {
    // MARK: - Framing

    @Test
    func request_roundtrips_with_newline_framing() throws {
        let request = ControlRequest(command: "pane.list", args: ControlArgs(project: "demo", tab: "tab:2"))
        let encoded = try ControlProtocol.encode(request)
        #expect(encoded.last == 0x0A)
        let decoded = try ControlProtocol.decodeRequest(encoded)
        #expect(decoded.id == request.id)
        #expect(decoded.command == "pane.list")
        #expect(decoded.args == ControlArgs(project: "demo", tab: "tab:2"))
        #expect(decoded.v == ControlProtocol.version)
    }

    @Test
    func response_roundtrips_success_and_failure() throws {
        let success = ControlResponse.success(
            id: "abc",
            data: ControlData(status: ControlStatusInfo(version: "1.0", pid: 42, activeProject: "p", activeProjectID: nil))
        )
        let decodedSuccess = try ControlProtocol.decodeResponse(ControlProtocol.encode(success))
        #expect(decodedSuccess.ok)
        #expect(decodedSuccess.id == "abc")
        #expect(decodedSuccess.data?.status?.pid == 42)
        #expect(decodedSuccess.error == nil)

        let failure = ControlResponse.failure(
            id: "def",
            error: ControlError(code: .notFound, message: "nope", action: "look elsewhere")
        )
        let decodedFailure = try ControlProtocol.decodeResponse(ControlProtocol.encode(failure))
        #expect(!decodedFailure.ok)
        #expect(decodedFailure.error?.code == .notFound)
        #expect(decodedFailure.error?.action == "look elsewhere")
    }

    /// The wire format the CLI emits, hand-built: guards against accidental
    /// key renames on the app side.
    @Test
    func app_decodes_hand_built_cli_request() throws {
        let json = #"{"v":1,"id":"x1","command":"session.info","args":{"session":"macterm-demo-abc123"}}"#
        let decoded = try ControlProtocol.decodeRequest(Data((json + "\n").utf8))
        #expect(decoded.command == "session.info")
        #expect(decoded.args?.session == "macterm-demo-abc123")
    }

    /// Unknown args keys must be ignored (forward compatibility: a newer CLI
    /// against an older app).
    @Test
    func unknown_args_fields_are_ignored() throws {
        let json = #"{"v":1,"id":"x2","command":"status","args":{"future_flag":"yes"}}"#
        let decoded = try ControlProtocol.decodeRequest(Data((json + "\n").utf8))
        #expect(decoded.command == "status")
        #expect(decoded.args == ControlArgs())
    }

    @Test
    func error_codes_use_snake_case_raw_values() {
        #expect(ControlErrorCode.notFound.rawValue == "not_found")
        #expect(ControlErrorCode.unknownCommand.rawValue == "unknown_command")
        #expect(ControlErrorCode.noSurface.rawValue == "no_surface")
        #expect(ControlErrorCode.badRequest.rawValue == "bad_request")
        #expect(ControlErrorCode.internalError.rawValue == "internal")
    }

    @Test
    func decode_tolerates_trailing_whitespace_and_crlf() throws {
        let json = #"{"v":1,"id":"x3","command":"status"}"#
        let decoded = try ControlProtocol.decodeRequest(Data((json + "\r\n").utf8))
        #expect(decoded.command == "status")
    }

    // MARK: - New verbs (#165/#166/#167)

    @Test
    func request_roundtrips_new_args_fields() throws {
        let args = ControlArgs(pane: "pane:2", scrollback: true, axis: "vertical", ratio: 0.42)
        let request = ControlRequest(command: "pane.resize-split", args: args)
        let decoded = try ControlProtocol.decodeRequest(ControlProtocol.encode(request))
        #expect(decoded.args?.scrollback == true)
        #expect(decoded.args?.axis == "vertical")
        #expect(decoded.args?.ratio == 0.42)
        #expect(decoded.args == args)
    }

    @Test
    func response_roundtrips_inspect_payload() throws {
        let inspect = ControlPaneInspect(
            id: "pane-id", session: "macterm-demo-abc123def456",
            cols: 80, rows: 24, cellWidthPx: 8, cellHeightPx: 17, widthPx: 640, heightPx: 408,
            scrollbackTotal: 204, scrollbackOffset: 0, scrollbackLen: 24,
            altScreen: false, contentScale: 2.0,
            foregroundPID: 4242, foregroundArgv: ["hx", "src/main.rs"],
            processExited: false, needsConfirmQuit: true
        )
        let response = ControlResponse.success(id: "i1", data: ControlData(inspect: inspect))
        let decoded = try ControlProtocol.decodeResponse(ControlProtocol.encode(response))
        #expect(decoded.data?.inspect == inspect)
    }

    @Test
    func response_roundtrips_dump_payload() throws {
        let dump = ControlPaneDump(
            id: "pane-id", session: "macterm-demo-abc123def456",
            scrollback: true, bytes: 5, text: "hello"
        )
        let response = ControlResponse.success(id: "d1", data: ControlData(dump: dump))
        let decoded = try ControlProtocol.decodeResponse(ControlProtocol.encode(response))
        #expect(decoded.data?.dump == dump)
    }
}
