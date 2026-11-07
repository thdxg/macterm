import Foundation
@testable import Macterm
import Testing

/// Frames that the Zig side encoded (`server/schema/frames.json`, written by
/// `schema.fixtures` in `server/src/protocol/schema.zig`). The Swift side
/// must decode each one to the values that the Zig code put in, and encode
/// it again to the same bytes.
struct ProtocolFixtureTests {
    private struct Fixture: Decodable {
        let name: String
        let frame: String
        let reencodes: Bool
    }

    private static let fixtures: [String: (bytes: Data, reencodes: Bool)] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Protocol
            .deletingLastPathComponent() // MactermTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("server/schema/frames.json")
        let data = (try? Data(contentsOf: url)) ?? Data()
        let list = (try? JSONDecoder().decode([Fixture].self, from: data)) ?? []
        return Dictionary(uniqueKeysWithValues: list.map { ($0.name, (bytes(hex: $0.frame), $0.reencodes)) })
    }()

    private static func bytes(hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index ..< next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    /// The fixture's frame on channel 0, decoded.
    private static func control(_ name: String) throws -> ProtocolControl {
        let bytes = try #require(fixtures[name]?.bytes, "no fixture \(name)")
        let parsed = try #require(try ProtocolFrame.parse(bytes))
        #expect(parsed.length == bytes.count)
        #expect(parsed.frame.channel == ProtocolFrame.controlChannel)
        #expect(parsed.frame.kind == .msg)
        return try ProtocolControl.decode(parsed.frame.body)
    }

    @Test
    func every_fixture_is_here() {
        #expect(Set(Self.fixtures.keys) == [
            "hello", "refuse",
            "channel.open request", "channel.open result",
            "channel.close request", "channel.close result",
            "error", "events", "later hello", "pane bytes",
        ])
    }

    @Test
    func every_fixture_encodes_again_to_the_bytes_of_the_Zig_side() throws {
        for (name, fixture) in Self.fixtures where fixture.reencodes {
            let parsed = try #require(try ProtocolFrame.parse(fixture.bytes))
            var frame = parsed.frame
            if frame.kind == .msg {
                frame.body = try #require(ProtocolControl.decode(frame.body).encoded(), "\(name)")
            }
            #expect(try frame.encoded() == fixture.bytes, "\(name)")
        }
    }

    @Test
    func the_handshake_decodes() throws {
        let hello = MactermProtocol.Hello(
            level: 1,
            minLevel: 1,
            build: "2.0.0-tip.1",
            role: .gui,
            epoch: 0x1234_5678_9ABC_DEF0,
            caps: ["tcc", "password-tty"]
        )
        #expect(try Self.control("hello") == .hello(hello))
        #expect(try Self.control("refuse") == .refuse(.init(reason: "level_too_low", needsLevel: 4)))
    }

    @Test
    func requests_and_results_decode_as_their_methods() throws {
        guard case let .request(open) = try Self.control("channel.open request") else {
            Issue.record("not a request")
            return
        }
        #expect(open.id == 7)
        #expect(open.m == MactermProtocol.ChannelOpen.name)
        #expect(try open.args(of: MactermProtocol.ChannelOpen.self) == .init(session: "macterm-abc"))
        #expect(open == MactermProtocol.Request(id: 7, method: MactermProtocol.ChannelOpen.self, args: .init(session: "macterm-abc")))

        guard case let .response(opened) = try Self.control("channel.open result") else {
            Issue.record("not a response")
            return
        }
        #expect(opened.re == 7)
        #expect(try opened.result(of: MactermProtocol.ChannelOpen.self) == .init(channel: 2))

        guard case let .request(close) = try Self.control("channel.close request") else {
            Issue.record("not a request")
            return
        }
        #expect(try close.args(of: MactermProtocol.ChannelClose.self) == .init(channel: 2))

        guard case let .response(closed) = try Self.control("channel.close result") else {
            Issue.record("not a response")
            return
        }
        #expect(try closed.result(of: MactermProtocol.ChannelClose.self) == .init())
    }

    @Test
    func an_error_response_decodes_and_its_result_is_the_error() throws {
        guard case let .response(failed) = try Self.control("error") else {
            Issue.record("not a response")
            return
        }
        let info = MactermProtocol.ErrorInfo(code: "unknown_method", message: "No method pane.fly.", level: 3)
        #expect(failed == .init(re: 9, err: info))
        #expect(throws: ProtocolControlError.errorResponse(info)) {
            try failed.result(of: MactermProtocol.ChannelClose.self)
        }
    }

    @Test
    func an_event_batch_keeps_each_events_arguments_as_bytes() throws {
        let batch = MactermProtocol.EventBatch(seq: 41, ev: [
            .init(e: "pane.title", a: ProtocolRaw(Data([0x81, 0xA1, 0x74, 0xA2, 0x68, 0x78]))),
            .init(e: "pane.bell"),
        ])
        #expect(try Self.control("events") == .events(batch))
    }

    @Test
    func a_hello_from_a_later_build_decodes_with_its_new_role_as_unknown() throws {
        guard case let .hello(hello) = try Self.control("later hello") else {
            Issue.record("not a hello")
            return
        }
        #expect(hello.level == 9)
        #expect(hello.role == .unknown)
        #expect(hello.caps == ["tcc", "teleport"])
    }

    @Test
    func pane_bytes_pass_as_they_are() throws {
        let bytes = try #require(Self.fixtures["pane bytes"]?.bytes)
        let parsed = try #require(try ProtocolFrame.parse(bytes))
        #expect(parsed.frame == ProtocolFrame(channel: 3, kind: .bytes, body: Data("ls\r".utf8)))
    }

    @Test
    func the_schemas_own_rules_hold() {
        #expect(MactermProtocol.minLevel <= MactermProtocol.level)
        #expect(MactermProtocol.Hello.name == "hello")
        #expect(MactermProtocol.ChannelOpen.senders == [.local])
        #expect(MactermProtocol.Hello.senders == [.local, .session, .remote])
    }
}
