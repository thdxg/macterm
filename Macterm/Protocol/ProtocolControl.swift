import Foundation

/// A message that the schema names: `hello`, `refuse`, and each event.
protocol ProtocolMessage: ProtocolValue {
    static var name: String { get }
    static var since: UInt32 { get }
    /// The trust levels of the connections that may send it (design/006 §2).
    static var senders: [MactermProtocol.Trust] { get }
}

/// A request method of the schema, with the types of its arguments and its
/// result.
protocol ProtocolMethod {
    associatedtype Args: ProtocolValue
    associatedtype Result: ProtocolValue
    static var name: String { get }
    static var since: UInt32 { get }
    /// The trust levels of the connections that may send it (design/006 §2).
    static var senders: [MactermProtocol.Trust] { get }
}

/// One message on channel 0, as `decodeControl` in
/// `server/src/protocol/messages.zig` reads it.
enum ProtocolControl: Equatable {
    case hello(MactermProtocol.Hello)
    case refuse(MactermProtocol.Refuse)
    case request(MactermProtocol.Request)
    case response(MactermProtocol.Response)
    case events(MactermProtocol.EventBatch)
    /// A message of a kind that a later build added. Ignore it.
    case unknown

    /// Decodes the body of a channel-0 frame. The keys name its kind: `m` a
    /// request, `re` a response, `seq` an event batch, `needs_level` a
    /// refusal, `level` a hello. These keys are frozen with the shapes, and
    /// the first in that order wins.
    static func decode(_ body: Data) throws -> ProtocolControl {
        enum Kind: Int, Comparable {
            case request, response, events, refuse, hello, unknown

            static func < (lhs: Kind, rhs: Kind) -> Bool {
                lhs.rawValue < rhs.rawValue
            }
        }
        var kind = Kind.unknown
        // As the Zig side does: the keys at the top, with no depth for the
        // map itself.
        var reader = MessagePackReader(body)
        for _ in try 0 ..< (reader.readMapLength()) {
            let found: Kind = switch try reader.readString() {
            case "m": .request
            case "re": .response
            case "seq": .events
            case "needs_level": .refuse
            case "level": .hello
            default: .unknown
            }
            kind = min(kind, found)
            try reader.skip()
        }
        switch kind {
        case .request:
            return try .request(MessagePackReader.decode(MactermProtocol.Request.self, from: body))
        case .response:
            let response = try MessagePackReader.decode(MactermProtocol.Response.self, from: body)
            guard (response.ok == nil) != (response.err == nil) else { throw MessagePackError.wrongType }
            return .response(response)
        case .events:
            return try .events(MessagePackReader.decode(MactermProtocol.EventBatch.self, from: body))
        case .refuse:
            return try .refuse(MessagePackReader.decode(MactermProtocol.Refuse.self, from: body))
        case .hello:
            return try .hello(MessagePackReader.decode(MactermProtocol.Hello.self, from: body))
        case .unknown:
            return .unknown
        }
    }

    /// The MessagePack body of the message. `unknown` has none.
    func encoded() -> Data? {
        switch self {
        case let .hello(value): MessagePackWriter.encode(value)
        case let .refuse(value): MessagePackWriter.encode(value)
        case let .request(value): MessagePackWriter.encode(value)
        case let .response(value): MessagePackWriter.encode(value)
        case let .events(value): MessagePackWriter.encode(value)
        case .unknown: nil
        }
    }
}

enum ProtocolControlError: Error, Equatable {
    /// The response is an error: read its `err`.
    case errorResponse(MactermProtocol.ErrorInfo)
}

extension MactermProtocol.Request {
    init<M: ProtocolMethod>(id: UInt64, method _: M.Type, args: M.Args) {
        self.init(id: id, m: M.name, a: ProtocolRaw(encoding: args))
    }

    /// The arguments as the method's type. A request with no arguments reads
    /// as an empty map.
    func args<M: ProtocolMethod>(of _: M.Type) throws -> M.Args {
        try MessagePackReader.decode(M.Args.self, from: a?.bytes ?? Data([0x80]))
    }
}

extension MactermProtocol.Response {
    init<M: ProtocolMethod>(re: UInt64, method _: M.Type, result: M.Result) {
        self.init(re: re, ok: ProtocolRaw(encoding: result))
    }

    /// The result as the method's type, or `ProtocolControlError.errorResponse`.
    func result<M: ProtocolMethod>(of _: M.Type) throws -> M.Result {
        if let ok { return try ok.decode(M.Result.self) }
        if let err { throw ProtocolControlError.errorResponse(err) }
        throw MessagePackError.missingField("ok")
    }
}
