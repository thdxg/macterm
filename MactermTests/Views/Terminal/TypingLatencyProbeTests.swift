import AppKit
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

    @Test
    func theCursorCellIsTheRowAboveTheIMEPointsBottomEdge() {
        // A 400 pt view, a cell 8 pt wide and 16 pt high: the IME point is
        // the middle of the cell (x 104) and its bottom edge, 48 pt from the
        // top, so the cell spans 32...48 pt from the top.
        let cell = TypingLatencyProbe.cursorCell(imeX: 104, imeY: 48, height: 16, cellWidth: 8, boundsHeight: 400)
        #expect(cell == NSRect(x: 100, y: 352, width: 8, height: 16))
    }

    @Test
    func noCellWithoutASize() {
        #expect(TypingLatencyProbe.cursorCell(imeX: 4, imeY: 16, height: 0, cellWidth: 8, boundsHeight: 400) == nil)
        #expect(TypingLatencyProbe.cursorCell(imeX: 4, imeY: 16, height: 16, cellWidth: 0, boundsHeight: 400) == nil)
    }
}
