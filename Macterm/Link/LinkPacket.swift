import CryptoKit
import Foundation

/// The packet layer of the roaming link (design/009 §2), as
/// `server/src/link/packet.zig` writes it:
///
/// `key_id u32` · `counter u64` · sealed payload and 16 byte tag
///
/// The header is little-endian. Bit 63 of the counter is the direction. The
/// nonce is 4 zero bytes and the counter. The associated data is the header.
/// The cipher is CryptoKit's ChaCha20-Poly1305. This type has the nonce, the
/// replay window and the roam rule, and nothing else: no I/O, no address.
///
/// One codec for each key, for the life of that key. It is a class so that a
/// copy can never repeat a counter: the same counter under the same key is a
/// nonce reuse. Never make a second codec for a key that a first one used.
/// After `open` throws, nothing in the codec changed.
final class LinkPacketCodec {
    enum Direction {
        case clientToHost
        case hostToClient
    }

    enum Failure: Error, Equatable {
        case badKey
        case malformed
        case rejected
        case wrongDirection
        case replay
        case exhausted
    }

    struct Opened: Equatable {
        var payload: Data
        var counter: UInt64
        /// The counter is higher than any accepted before. Only then may the
        /// caller move the peer's address.
        var newest: Bool
    }

    static let headerLength = 12
    static let tagLength = 16
    static let overhead = headerLength + tagLength
    static let maxPacket = 1200
    static let maxPayload = maxPacket - overhead
    static let counterLimit: UInt64 = 1 << 48
    static let windowBits: UInt64 = 64
    private static let directionBit: UInt64 = 1 << 63

    let keyID: UInt32
    let sends: Direction
    private let key: SymmetricKey
    /// Test only: a codec near the end of its counter.
    var nextCounter: UInt64 {
        get { next }
        set { next = newValue }
    }

    private var next: UInt64 = 1
    private var highest: UInt64 = 0
    /// Bit i is set when `highest - i` was accepted.
    private var seen: UInt64 = 0

    init(key: Data, keyID: UInt32, sends: Direction) throws {
        guard key.count == 32 else { throw Failure.badKey }
        self.key = SymmetricKey(data: key)
        self.keyID = keyID
        self.sends = sends
    }

    func seal(_ payload: Data) throws -> Data {
        guard payload.count <= Self.maxPayload else { throw Failure.malformed }
        guard next < Self.counterLimit else { throw Failure.exhausted }
        let counter = next | (sends == .hostToClient ? Self.directionBit : 0)
        next += 1
        var header = Data()
        header.append(littleEndian: keyID)
        header.append(littleEndian: counter)
        let box = try ChaChaPoly.seal(payload, using: key, nonce: Self.nonce(counter), authenticating: header)
        return header + box.ciphertext + box.tag
    }

    func open(_ packet: Data) throws -> Opened {
        let bytes = Data(packet)
        guard bytes.count >= Self.overhead, bytes.count <= Self.maxPacket else { throw Failure.malformed }
        guard bytes.readLittleEndian(UInt32.self, at: 0) == keyID else { throw Failure.rejected }
        let counter = bytes.readLittleEndian(UInt64.self, at: 4)
        let fromHost = counter & Self.directionBit != 0
        guard fromHost != (sends == .hostToClient) else { throw Failure.wrongDirection }
        let n = counter & ~Self.directionBit
        guard n != 0, n < Self.counterLimit else { throw Failure.rejected }
        guard !replayed(n) else { throw Failure.replay }
        let header = bytes.prefix(Self.headerLength)
        let ciphertext = bytes.dropFirst(Self.headerLength).dropLast(Self.tagLength)
        let tag = bytes.suffix(Self.tagLength)
        let payload: Data
        do {
            let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(counter), ciphertext: ciphertext, tag: tag)
            payload = try ChaChaPoly.open(box, using: key, authenticating: header)
        } catch {
            throw Failure.rejected
        }
        let newest = n > highest
        accept(n)
        return Opened(payload: payload, counter: n, newest: newest)
    }

    private func replayed(_ n: UInt64) -> Bool {
        if n > highest { return false }
        let back = highest - n
        if back >= Self.windowBits { return true }
        return (seen >> UInt64(back)) & 1 == 1
    }

    private func accept(_ n: UInt64) {
        if n > highest {
            let shift = n - highest
            seen = shift >= Self.windowBits ? 0 : seen << UInt64(shift)
            seen |= 1
            highest = n
        } else {
            seen |= UInt64(1) << UInt64(highest - n)
        }
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var data = Data(count: 4)
        data.append(littleEndian: counter)
        return try ChaChaPoly.Nonce(data: data)
    }
}

private extension Data {
    mutating func append(littleEndian value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readLittleEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        var value: T = 0
        for i in 0 ..< MemoryLayout<T>.size {
            value |= T(truncatingIfNeeded: self[startIndex + offset + i]) << (8 * i)
        }
        return value
    }
}
