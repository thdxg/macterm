import Foundation
@testable import Macterm
import Testing

/// The same cases as the tests of `server/src/link/packet.zig`, and its
/// test vector: the two sides must make the same bytes.
struct LinkPacketTests {
    private static let key = Data((0 ..< 32).map { UInt8($0) })

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func pair() -> (client: LinkPacketCodec, host: LinkPacketCodec) {
        (
            LinkPacketCodec(key: Self.key, keyID: 7, sends: .clientToHost),
            LinkPacketCodec(key: Self.key, keyID: 7, sends: .hostToClient)
        )
    }

    @Test
    func the_shared_test_vector() throws {
        var link = LinkPacketCodec(key: Self.key, keyID: 0x0102_0304, sends: .clientToHost)
        let packet = try link.seal(Data("macterm link".utf8))
        #expect(Self.hex(packet) == "040302010100000000000000f236902bd058c23845dfc037c34bd5dd6f6bddfca6442b095c60b507")
    }

    @Test
    func a_packet_goes_through_both_ways() throws {
        var (client, host) = pair()
        let opened = try host.open(client.seal(Data("hello".utf8)))
        #expect(opened.payload == Data("hello".utf8))
        #expect(opened.newest)
        #expect(opened.counter == 1)
        let back = try client.open(host.seal(Data()))
        #expect(back.payload.isEmpty)
    }

    @Test
    func a_flipped_bit_is_rejected() throws {
        var (client, host) = pair()
        let packet = try client.seal(Data("hello".utf8))
        for i in 0 ..< packet.count {
            var copy = packet
            copy[i] ^= 1
            #expect(throws: LinkPacketCodec.Failure.self) { _ = try host.open(copy) }
        }
        _ = try host.open(packet)
    }

    @Test
    func replays_and_reflections_are_refused() throws {
        var (client, host) = pair()
        let packet = try client.seal(Data("x".utf8))
        #expect(throws: LinkPacketCodec.Failure.wrongDirection) { _ = try client.open(packet) }
        _ = try host.open(packet)
        #expect(throws: LinkPacketCodec.Failure.replay) { _ = try host.open(packet) }
    }

    @Test
    func the_window_takes_late_packets_once() throws {
        var (client, host) = pair()
        let packets = try (0 ..< 200).map { _ in try client.seal(Data("x".utf8)) }
        #expect(try host.open(packets[149]).newest)
        #expect(try !host.open(packets[99]).newest)
        #expect(throws: LinkPacketCodec.Failure.replay) { _ = try host.open(packets[99]) }
        #expect(throws: LinkPacketCodec.Failure.replay) { _ = try host.open(packets[0]) }
    }

    @Test
    func another_key_or_key_id_is_refused() throws {
        var (_, host) = pair()
        var otherID = LinkPacketCodec(key: Self.key, keyID: 8, sends: .clientToHost)
        #expect(throws: LinkPacketCodec.Failure.rejected) { _ = try host.open(otherID.seal(Data("x".utf8))) }
        var otherKey = LinkPacketCodec(key: Data(repeating: 1, count: 32), keyID: 7, sends: .clientToHost)
        #expect(throws: LinkPacketCodec.Failure.rejected) { _ = try host.open(otherKey.seal(Data("x".utf8))) }
    }

    @Test
    func size_limits() throws {
        var (client, host) = pair()
        #expect(throws: LinkPacketCodec.Failure.malformed) {
            _ = try client.seal(Data(count: LinkPacketCodec.maxPayload + 1))
        }
        #expect(throws: LinkPacketCodec.Failure.malformed) { _ = try host.open(Data(count: 10)) }
        let full = try client.seal(Data(count: LinkPacketCodec.maxPayload))
        #expect(full.count == LinkPacketCodec.maxPacket)
        _ = try host.open(full)
    }
}
