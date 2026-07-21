import AppKit
@preconcurrency import IOSurface
@testable import Macterm
import Testing

@MainActor
struct AdaptiveTerminalBackgroundTests {
    private func pixel(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8 = 255)
        -> AdaptiveTerminalBackgroundDetector.Pixel
    {
        .init(red: red, green: green, blue: blue, alpha: alpha)
    }

    @Test
    func dominantOpaqueColorWinsWhenItCoversMostOfFrame() throws {
        let background = Array(repeating: pixel(18, 20, 24), count: 70)
        let transparent = Array(repeating: pixel(220, 220, 220, 0), count: 30)

        let match = try #require(AdaptiveTerminalBackgroundDetector.dominantColor(in: background + transparent))

        #expect(match.red == 18)
        #expect(match.green == 20)
        #expect(match.blue == 24)
        #expect(match.coverage == 0.7)
    }

    @Test
    func sparseOpaqueTextCannotTriggerMatching() {
        let text = Array(repeating: pixel(230, 230, 240), count: 25)
        let transparent = Array(repeating: pixel(0, 0, 0, 0), count: 75)

        #expect(AdaptiveTerminalBackgroundDetector.dominantColor(in: text + transparent) == nil)
    }

    @Test
    func variedOpaqueFrameDoesNotProduceFalseDominantColor() {
        let first = Array(repeating: pixel(20, 20, 20), count: 50)
        let second = Array(repeating: pixel(80, 40, 120), count: 50)

        #expect(AdaptiveTerminalBackgroundDetector.dominantColor(in: first + second) == nil)
    }

    @Test
    func nearbyRendererValuesShareAQuantizedBucket() throws {
        let first = Array(repeating: pixel(17, 18, 19), count: 35)
        let second = Array(repeating: pixel(20, 21, 22), count: 35)
        let transparent = Array(repeating: pixel(0, 0, 0, 0), count: 30)

        let match = try #require(
            AdaptiveTerminalBackgroundDetector.dominantColor(in: first + second + transparent)
        )
        #expect(match.red == 18)
        #expect(match.green == 19)
        #expect(match.blue == 20)
        #expect(match.coverage == 0.7)
    }

    @Test
    func samplesGhosttyBGRAIOSurface() throws {
        let properties = [
            kIOSurfaceWidth: NSNumber(value: 40),
            kIOSurfaceHeight: NSNumber(value: 30),
            kIOSurfaceBytesPerElement: NSNumber(value: 4),
        ] as CFDictionary
        guard let surface = IOSurfaceCreate(properties) else {
            Issue.record("Could not create the test IOSurface")
            return
        }
        var seed: UInt32 = 0
        #expect(IOSurfaceLock(surface, [], &seed) == kIOReturnSuccess)
        let base = IOSurfaceGetBaseAddress(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        for y in 0 ..< IOSurfaceGetHeight(surface) {
            for x in 0 ..< IOSurfaceGetWidth(surface) {
                let offset = y * bytesPerRow + x * 4
                base.storeBytes(of: UInt8(31), toByteOffset: offset, as: UInt8.self)
                base.storeBytes(of: UInt8(21), toByteOffset: offset + 1, as: UInt8.self)
                base.storeBytes(of: UInt8(11), toByteOffset: offset + 2, as: UInt8.self)
                base.storeBytes(of: UInt8(255), toByteOffset: offset + 3, as: UInt8.self)
            }
        }
        #expect(IOSurfaceUnlock(surface, [], &seed) == kIOReturnSuccess)

        let match = try #require(AdaptiveTerminalBackgroundDetector.dominantColor(in: surface))
        #expect(match.red == 11)
        #expect(match.green == 21)
        #expect(match.blue == 31)
        #expect(match.coverage == 1)
    }

    @Test
    func stabilizerRequiresTwoMatchingObservationsToApplyAndClear() {
        var stabilizer = AdaptiveTerminalBackgroundStabilizer()
        let color = NSColor(srgbRed: 0.12, green: 0.18, blue: 0.24, alpha: 1)

        #expect(stabilizer.observe(color) == nil)
        #expect(stabilizer.hasPendingObservation)
        #expect(stabilizer.observe(color) == .applyColor)
        #expect(!stabilizer.hasPendingObservation)

        #expect(stabilizer.observe(nil) == nil)
        #expect(stabilizer.hasPendingObservation)
        #expect(stabilizer.observe(nil) == .clear)
        #expect(!stabilizer.hasPendingObservation)
    }

    @Test
    func stabilizerRejectsAnInterruptedCandidate() {
        var stabilizer = AdaptiveTerminalBackgroundStabilizer()
        let first = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        let second = NSColor(srgbRed: 0.7, green: 0.2, blue: 0.1, alpha: 1)

        #expect(stabilizer.observe(first) == nil)
        #expect(stabilizer.observe(second) == nil)
        #expect(stabilizer.observe(first) == nil)
        #expect(stabilizer.observe(first) == .applyColor)
    }

    @Test
    func stabilizerTreatsTinyRendererVarianceAsTheSameColor() {
        var stabilizer = AdaptiveTerminalBackgroundStabilizer()
        let first = NSColor(srgbRed: 0.200, green: 0.300, blue: 0.400, alpha: 1)
        let second = NSColor(srgbRed: 0.202, green: 0.302, blue: 0.402, alpha: 1)

        #expect(stabilizer.observe(first) == nil)
        #expect(stabilizer.observe(second) == .applyColor)
    }

    @Test
    func stabilizerResetAdoptsKnownStateWithoutAChange() {
        var stabilizer = AdaptiveTerminalBackgroundStabilizer()
        let color = NSColor(srgbRed: 0.3, green: 0.4, blue: 0.5, alpha: 1)

        stabilizer.reset(to: color)

        #expect(stabilizer.observe(color) == nil)
        #expect(!stabilizer.hasPendingObservation)
    }

    @Test
    func stabilizerSeededWithRememberedColorTreatsItAsCurrent() {
        let remembered = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1)
        var stabilizer = AdaptiveTerminalBackgroundStabilizer(seededWith: remembered)

        // Re-observing the remembered color is a no-op (no re-detection flash)…
        #expect(stabilizer.observe(remembered) == nil)
        #expect(!stabilizer.hasPendingObservation)

        // …while a TUI that exited off-screen still clears via two observations.
        #expect(stabilizer.observe(nil) == nil)
        #expect(stabilizer.observe(nil) == .clear)
    }

    @Test
    func singlePaneColorTintsTheWindowAndFillsItsOwnPane() throws {
        let color = NSColor(srgbRed: 0.2, green: 0.3, blue: 0.4, alpha: 1)

        let window = try #require(AdaptiveTerminalBackgroundPresentation.windowColor(for: [color]))
        #expect(window.isVisuallyEqual(to: color))
        // The pane fill stays opaque even when the window tint is translucent,
        // so the padding around the TUI shows no seam.
        #expect(AdaptiveTerminalBackgroundPresentation.paneColors(for: [color]) == [color])
    }

    @Test
    func splitColorsStayInsideTheirOwnPanes() {
        let grok = NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1)
        let paneColors = AdaptiveTerminalBackgroundPresentation.paneColors(for: [grok, nil])

        #expect(AdaptiveTerminalBackgroundPresentation.windowColor(for: [grok, nil]) == nil)
        #expect(paneColors[0]?.isVisuallyEqual(to: grok) == true)
        #expect(paneColors[1] == nil)
    }
}
