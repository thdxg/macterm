import Foundation
@testable import Macterm
import Testing

/// A pane channel against the bundled server, in a runtime directory of its
/// own (see `LocalServerTests`).
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PaneChannelTests {
    @Test
    func a_channel_attaches_gets_output_sends_input_and_sees_the_exit() async throws {
        try await withServer { server in
            let connection = try await server.connect()
            defer { connection.close() }
            let id = "chan-\(UInt32.random(in: 0 ... .max))"
            // The first output is the marker that shows the channel reads the
            // pane. The program echoes one line of input, then exits.
            _ = try await connection.call(
                MactermProtocol.SessionCreate.self,
                Self.args(id: id, command: ["/bin/sh", "-c", "printf ready-%s ok; read line; printf got-%s \"$line\"; exit 4"])
            )
            let channel = try await connection.openChannel(session: id)
            try channel.send(MactermProtocol.Attach(cols: 80, rows: 24))
            var iterator = channel.events.makeAsyncIterator()
            var screen = Data()
            while !String(decoding: screen, as: UTF8.self).contains("ready-ok") {
                guard let event = await iterator.next() else { Issue.record("no output")
                    return
                }
                if case let .output(data) = event { screen.append(data) }
            }
            try channel.sendInput(Data("hello\n".utf8))
            var exit: MactermProtocol.Exit?
            while exit == nil {
                guard let event = await iterator.next() else { break }
                switch event {
                case let .output(data): screen.append(data)
                case let .exit(value): exit = value
                default: break
                }
            }
            #expect(String(decoding: screen, as: UTF8.self).contains("got-hello"))
            #expect(exit?.code == 4)
            await channel.close()
        }
    }

    @Test
    func a_burst_of_output_right_after_the_open_arrives_whole_and_in_order() async throws {
        try await withServer { server in
            let connection = try await server.connect()
            defer { connection.close() }
            let id = "chan-burst-\(UInt32.random(in: 0 ... .max))"
            _ = try await connection.call(
                MactermProtocol.SessionCreate.self,
                Self.args(id: id, command: ["/bin/sh", "-c", "i=1; while [ $i -le 3000 ]; do echo n$i; i=$((i+1)); done; sleep 30"])
            )
            let channel = try await connection.openChannel(session: id)
            try channel.send(MactermProtocol.Attach(cols: 200, rows: 24))
            var iterator = channel.events.makeAsyncIterator()
            var screen = Data()
            while !String(decoding: screen, as: UTF8.self).contains("n3000") {
                guard let event = await iterator.next() else { Issue.record("ended early")
                    return
                }
                if case let .output(data) = event { screen.append(data) }
            }
            let numbers = String(decoding: screen, as: UTF8.self)
                .split(whereSeparator: \.isNewline).compactMap { $0.hasPrefix("n") ? Int($0.dropFirst()) : nil }
            // A snapshot may repeat lines that output carries too, but a line never
            // comes before an earlier one.
            #expect(numbers == numbers.sorted())
            #expect(numbers.last == 3000)
            await channel.close()
        }
    }

    @Test
    func a_closed_connection_ends_the_events_of_its_channels() async throws {
        try await withServer { server in
            let connection = try await server.connect()
            let id = "chan-end-\(UInt32.random(in: 0 ... .max))"
            _ = try await connection.call(
                MactermProtocol.SessionCreate.self,
                Self.args(id: id, command: ["/bin/sleep", "60"])
            )
            let channel = try await connection.openChannel(session: id)
            connection.close()
            var iterator = channel.events.makeAsyncIterator()
            while await iterator.next() != nil {}
            #expect(throws: ServerClientError.self) { try channel.sendInput(Data("x".utf8)) }
        }
    }

    @Test
    func events_decode_output_and_the_sessions_messages() {
        let output = ProtocolFrame(channel: 3, kind: .bytes, body: Data("abc".utf8))
        #expect(PaneChannelEvent(output) == .output(Data("abc".utf8)))

        var writer = MessagePackWriter()
        MactermProtocol.PaneMessage(MactermProtocol.Lead(leader: true)).encode(to: &writer)
        let lead = ProtocolFrame(channel: 3, kind: .msg, body: writer.data)
        #expect(PaneChannelEvent(lead) == .lead(true))

        var unknown = MessagePackWriter()
        MactermProtocol.PaneMessage(t: "from.a.later.build", a: nil).encode(to: &unknown)
        #expect(PaneChannelEvent(ProtocolFrame(channel: 3, kind: .msg, body: unknown.data)) == .other("from.a.later.build"))
    }

    private static func args(id: String, command: [String]) -> MactermProtocol.SessionCreate.Args {
        .init(
            id: id,
            cwd: ProtocolBin(Data(NSTemporaryDirectory().utf8)),
            command: command.map { ProtocolBin(Data($0.utf8)) },
            cols: 80,
            rows: 24
        )
    }

    private func withServer(_ body: (LocalServer) async throws -> Void) async throws {
        let bundled = try #require(LocalServer.bundled, "zmx/zmx missing from the built bundle. Run `mise run setup`.")
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appending(path: "mt-\(UInt32.random(in: 0 ... .max))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var server = bundled
        server.directory = root.appending(path: "run", directoryHint: .isDirectory)
        do {
            try await body(server)
        } catch {
            await Self.cleanUp(server)
            throw error
        }
        await Self.cleanUp(server)
    }

    private static func cleanUp(_ server: LocalServer) async {
        guard let connection = try? ServerConnection.connect(path: server.socketPath) else { return }
        for session in await (try? connection.call(MactermProtocol.SessionList.self, .init()).sessions) ?? [] {
            _ = try? await connection.call(MactermProtocol.SessionKill.self, .init(id: session.id))
        }
        _ = try? await connection.call(MactermProtocol.ServerExit.self, .init())
        connection.close()
    }
}
