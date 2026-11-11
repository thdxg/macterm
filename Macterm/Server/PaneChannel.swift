import Foundation

/// What a pane channel delivers (design/003 §1): the session's output as raw
/// bytes, and its own messages. A message that this build does not know, or
/// cannot read, is `other`.
enum PaneChannelEvent: Equatable {
    /// Output of the pane, or the bytes of a snapshot between `snapshotStart`
    /// and `snapshotEnd`.
    case output(Data)
    case state(MactermProtocol.State)
    case lead(Bool)
    case snapshotStart(MactermProtocol.SnapshotStart)
    case snapshotEnd
    case resumed(MactermProtocol.Resumed)
    case exit(MactermProtocol.Exit)
    case title(Data)
    case foreground(MactermProtocol.Foreground)
    case other(String)

    init?(_ frame: ProtocolFrame) {
        switch frame.kind {
        case .bytes:
            self = .output(frame.body)
        case .msg:
            guard let message = try? MessagePackReader.decode(MactermProtocol.PaneMessage.self, from: frame.body) else {
                return nil
            }
            self = Self.decode(message) ?? .other(message.t)
        default:
            return nil
        }
    }

    private static func decode(_ message: MactermProtocol.PaneMessage) -> PaneChannelEvent? {
        switch message.t {
        case MactermProtocol.State.name:
            (try? message.message(of: MactermProtocol.State.self)).map(PaneChannelEvent.state)
        case MactermProtocol.Lead.name:
            (try? message.message(of: MactermProtocol.Lead.self)).map { .lead($0.leader) }
        case MactermProtocol.SnapshotStart.name:
            (try? message.message(of: MactermProtocol.SnapshotStart.self)).map(PaneChannelEvent.snapshotStart)
        case MactermProtocol.SnapshotEnd.name:
            .snapshotEnd
        case MactermProtocol.Resumed.name:
            (try? message.message(of: MactermProtocol.Resumed.self)).map(PaneChannelEvent.resumed)
        case MactermProtocol.Exit.name:
            (try? message.message(of: MactermProtocol.Exit.self)).map(PaneChannelEvent.exit)
        case MactermProtocol.Title.name:
            (try? message.message(of: MactermProtocol.Title.self)).map { .title($0.title.bytes) }
        case MactermProtocol.Foreground.name:
            (try? message.message(of: MactermProtocol.Foreground.self)).map(PaneChannelEvent.foreground)
        default:
            nil
        }
    }
}

/// One pane's channel on a `ServerConnection`: the surface's view of its
/// session. Output and the session's messages come through `events`, in
/// order, and end when the channel or the connection ends. Input never
/// waits for the server: a write that blocks is the caller's queue's.
final class PaneChannel: @unchecked Sendable {
    let number: UInt32
    let events: AsyncStream<PaneChannelEvent>

    private weak var connection: ServerConnection?
    let sink: Sink

    /// The reader thread's side: turns frames into events.
    final class Sink: @unchecked Sendable {
        private let continuation: AsyncStream<PaneChannelEvent>.Continuation

        init(_ continuation: AsyncStream<PaneChannelEvent>.Continuation) {
            self.continuation = continuation
        }

        func deliver(_ frame: ProtocolFrame) {
            if let event = PaneChannelEvent(frame) { continuation.yield(event) }
        }

        func finish() {
            continuation.finish()
        }
    }

    init(connection: ServerConnection, number: UInt32) {
        self.connection = connection
        self.number = number
        let (events, continuation) = AsyncStream.makeStream(of: PaneChannelEvent.self, bufferingPolicy: .unbounded)
        self.events = events
        sink = Sink(continuation)
    }

    /// Keys, pastes and terminal replies for the session. Never dropped.
    func sendInput(_ data: Data) throws {
        guard let connection else { throw ServerClientError.disconnected }
        try connection.send(frame: ProtocolFrame(channel: number, kind: .bytes, body: data))
    }

    /// A message of the pane (`attach`, `resize`, `claim`).
    func send(_ message: some ProtocolMessage) throws {
        var writer = MessagePackWriter()
        MactermProtocol.PaneMessage(message).encode(to: &writer)
        guard let connection else { throw ServerClientError.disconnected }
        try connection.send(frame: ProtocolFrame(channel: number, kind: .msg, body: writer.data))
    }

    /// Stops the output of a pane that no one sees. The session's messages
    /// still come. `resume` brings a snapshot first (design/003 §6).
    func pause() async throws {
        _ = try await connection?.call(MactermProtocol.ChannelPause.self, .init(channel: number))
    }

    func resume() async throws {
        _ = try await connection?.call(MactermProtocol.ChannelResume.self, .init(channel: number))
    }

    /// Ends the channel. The session keeps running.
    func close() async {
        _ = try? await connection?.call(MactermProtocol.ChannelClose.self, .init(channel: number))
        connection?.releaseChannel(number)
    }
}
