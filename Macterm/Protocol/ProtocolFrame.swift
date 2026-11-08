import Foundation

/// One frame of the protocol (design/003 §1), as `server/src/protocol/frame.zig`
/// writes it:
///
/// `length u32` · `channel u32` · `kind u8` · body
///
/// The header is little-endian. `length` counts the body only. Channel 0 is
/// control and carries only `msg`. Each other channel is one pane: `bytes`
/// is raw pty output or input, `msg` is the session's own messages.
struct ProtocolFrame: Equatable {
    static let headerLength = 9
    /// 16 MiB.
    static let maxBody = 16 * 1024 * 1024
    static let controlChannel: UInt32 = 0

    /// A kind that a later build adds passes on a pane channel, so that the
    /// receiver can ignore it.
    struct Kind: RawRepresentable, Equatable {
        var rawValue: UInt8

        /// One MessagePack value.
        static let msg = Kind(rawValue: 0)
        /// Raw pty bytes.
        static let bytes = Kind(rawValue: 1)
    }

    enum FrameError: Error, Equatable {
        /// The header gives a body over `maxBody`. The peer is broken or
        /// hostile: close the link.
        case tooLarge
        /// A `bytes` frame, or a kind this build does not know, on channel 0.
        case notAMessage
    }

    var channel: UInt32
    var kind: Kind
    var body: Data

    /// The frame with its header.
    func encoded() throws -> Data {
        guard body.count <= Self.maxBody else { throw FrameError.tooLarge }
        guard channel != Self.controlChannel || kind == .msg else { throw FrameError.notAMessage }
        var out = Data(capacity: Self.headerLength + body.count)
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: channel.littleEndian) { out.append(contentsOf: $0) }
        out.append(kind.rawValue)
        out.append(body)
        return out
    }

    /// Reads one frame from the start of `buffer`. Nil means that `buffer`
    /// holds no whole frame yet: read more and call again. An oversized
    /// length is an error as soon as the header is in.
    static func parse(_ buffer: Data) throws -> (frame: ProtocolFrame, length: Int)? {
        guard buffer.count >= headerLength else { return nil }
        let start = buffer.startIndex
        let length = Int(littleEndian(buffer, at: start))
        guard length <= maxBody else { throw FrameError.tooLarge }
        let channel = littleEndian(buffer, at: start + 4)
        let kind = Kind(rawValue: buffer[start + 8])
        guard channel != controlChannel || kind == .msg else { throw FrameError.notAMessage }
        let total = headerLength + length
        guard buffer.count >= total else { return nil }
        let body = Data(buffer[(start + headerLength) ..< (start + total)])
        return (ProtocolFrame(channel: channel, kind: kind, body: body), total)
    }

    private static func littleEndian(_ data: Data, at index: Data.Index) -> UInt32 {
        (0 ..< 4).reduce(UInt32(0)) { $0 | UInt32(data[index + $1]) << (8 * $1) }
    }
}
