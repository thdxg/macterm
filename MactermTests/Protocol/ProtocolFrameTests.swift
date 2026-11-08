import Foundation
@testable import Macterm
import Testing

/// The same cases as the tests of `server/src/protocol/frame.zig`.
struct ProtocolFrameTests {
    @Test
    func a_frame_round_trips_and_a_short_buffer_asks_for_more() throws {
        let pane = try ProtocolFrame(channel: 3, kind: .bytes, body: Data("ls\r".utf8)).encoded()
        #expect(Array(pane) == [3, 0, 0, 0, 3, 0, 0, 0, 1, 0x6C, 0x73, 0x0D])
        let control = try ProtocolFrame(channel: 0, kind: .msg, body: Data([0x80])).encoded()
        let stream = pane + control

        for count in 0 ..< pane.count {
            #expect(try ProtocolFrame.parse(stream.prefix(count)) == nil)
        }
        let first = try #require(try ProtocolFrame.parse(stream))
        #expect(first.length == 12)
        #expect(first.frame == ProtocolFrame(channel: 3, kind: .bytes, body: Data("ls\r".utf8)))
        // A buffer that does not start at index 0.
        let second = try #require(try ProtocolFrame.parse(stream.dropFirst(first.length)))
        #expect(second.frame == ProtocolFrame(channel: 0, kind: .msg, body: Data([0x80])))
    }

    @Test
    func an_empty_body_is_a_frame() throws {
        let parsed = try #require(try ProtocolFrame.parse(Data([0, 0, 0, 0, 1, 0, 0, 0, 1])))
        #expect(parsed.length == 9)
        #expect(parsed.frame.body.isEmpty)
    }

    @Test
    func an_oversized_frame_is_refused_from_its_header_alone() throws {
        let big = ProtocolFrame(channel: 1, kind: .bytes, body: Data(count: ProtocolFrame.maxBody + 1))
        #expect(throws: ProtocolFrame.FrameError.tooLarge) { try big.encoded() }
        var header = Data([0, 0, 0, 1, 1, 0, 0, 0, 1]) // exactly maxBody: wait for the body
        #expect(try ProtocolFrame.parse(header) == nil)
        header[0] = 1 // maxBody + 1
        #expect(throws: ProtocolFrame.FrameError.tooLarge) { try ProtocolFrame.parse(header) }
        let largest = Data([0xFF, 0xFF, 0xFF, 0xFF, 1, 0, 0, 0, 1])
        #expect(throws: ProtocolFrame.FrameError.tooLarge) { try ProtocolFrame.parse(largest) }
    }

    @Test
    func channel_0_carries_only_messages() {
        #expect(throws: ProtocolFrame.FrameError.notAMessage) {
            try ProtocolFrame(channel: 0, kind: .bytes, body: Data("x".utf8)).encoded()
        }
        #expect(throws: ProtocolFrame.FrameError.notAMessage) { try ProtocolFrame.parse(Data([0, 0, 0, 0, 0, 0, 0, 0, 1])) }
        #expect(throws: ProtocolFrame.FrameError.notAMessage) { try ProtocolFrame.parse(Data([0, 0, 0, 0, 0, 0, 0, 0, 9])) }
    }

    @Test
    func a_pane_channel_passes_a_kind_this_build_does_not_know() throws {
        let parsed = try #require(try ProtocolFrame.parse(Data([0, 0, 0, 0, 2, 0, 0, 0, 9])))
        #expect(parsed.frame.kind == ProtocolFrame.Kind(rawValue: 9))
    }
}
