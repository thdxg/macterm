import Foundation
@testable import Macterm
import Testing

struct TypingLatencyProbeTests {
    private let empty = Data([0, 0, 0, 0])
    private let cursor = Data([255, 255, 255, 255])
    private let glyph = Data([0, 255, 0, 255])

    private func at(_ seconds: Double, _ cell: Data) -> TypingLatencyProbe.Observation {
        TypingLatencyProbe.Observation(seconds: seconds, cell: cell)
    }

    @Test
    func theGlyphFrameIsTheFirstFrameThatShowsTheFinalCell() {
        let time = TypingLatencyProbe.glyphTime(
            before: cursor,
            observations: [at(0.004, cursor), at(0.011, glyph), at(0.020, glyph)]
        )
        #expect(time == 0.011)
    }

    @Test
    func aBlinkBeforeTheGlyphDoesNotCount() {
        let time = TypingLatencyProbe.glyphTime(
            before: cursor,
            observations: [at(0.003, empty), at(0.015, glyph), at(0.200, glyph)]
        )
        #expect(time == 0.015)
    }

    @Test
    func aCellThatEndsAsItStartedIsAMiss() {
        let time = TypingLatencyProbe.glyphTime(
            before: cursor,
            observations: [at(0.003, empty), at(0.250, cursor)]
        )
        #expect(time == nil)
    }

    @Test
    func noFrameIsAMiss() {
        #expect(TypingLatencyProbe.glyphTime(before: cursor, observations: []) == nil)
    }
}
