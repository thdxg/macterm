import AppKit
import CoreVideo
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
    func nearbyRendererValuesShareAQuantizedBucketAndReturnASampledColor() throws {
        let first = Array(repeating: pixel(17, 18, 19), count: 35)
        let second = Array(repeating: pixel(20, 21, 22), count: 35)
        let transparent = Array(repeating: pixel(0, 0, 0, 0), count: 30)

        let match = try #require(
            AdaptiveTerminalBackgroundDetector.dominantColor(in: first + second + transparent)
        )
        #expect(match.red == 17)
        #expect(match.green == 18)
        #expect(match.blue == 19)
        #expect(match.coverage == 0.7)
    }

    @Test
    func exactModeRepresentsAQuantizedBucket() throws {
        let lessFrequent = Array(repeating: pixel(17, 18, 19), count: 25)
        let mode = Array(repeating: pixel(20, 21, 22), count: 45)
        let transparent = Array(repeating: pixel(0, 0, 0, 0), count: 30)

        let match = try #require(
            AdaptiveTerminalBackgroundDetector.dominantColor(in: lessFrequent + mode + transparent)
        )
        #expect(match.red == 20)
        #expect(match.green == 21)
        #expect(match.blue == 22)
        #expect(match.coverage == 0.7)
    }

    @Test
    func cellsPaintedAtTheWindowOpacityStillCount() throws {
        // `background-opacity-cells` at a 0.86 window: ghostty writes the TUI's
        // background at alpha 220, premultiplied. The old fixed 230 floor threw
        // every one of these away, so the chrome never saw the TUI's color.
        let opacity = 0.864
        let alpha = UInt8(255 * opacity)
        let scale = Double(alpha) / 255
        func premultiplied(_ component: UInt8) -> UInt8 {
            UInt8((Double(component) * scale).rounded())
        }
        let painted = Array(
            repeating: pixel(premultiplied(200), premultiplied(100), premultiplied(50), alpha),
            count: 80
        )
        let unpainted = Array(repeating: pixel(0, 0, 0, 0), count: 20)

        let match = try #require(
            AdaptiveTerminalBackgroundDetector.dominantColor(
                in: painted + unpainted,
                minimumAlpha: AdaptiveTerminalBackgroundDetector.minimumPaintedAlpha(windowOpacity: opacity)
            )
        )

        // Un-premultiplied back to what the TUI asked for, give or take the
        // rounding the 8-bit round trip costs.
        #expect(abs(Int(match.red) - 200) <= 1)
        #expect(abs(Int(match.green) - 100) <= 1)
        #expect(abs(Int(match.blue) - 50) <= 1)
        #expect(match.alpha == alpha)
        #expect(match.coverage == 0.8)
    }

    @Test
    func minimumPaintedAlphaTracksTheWindowOpacityAndNeverAdmitsUnpaintedPixels() {
        #expect(AdaptiveTerminalBackgroundDetector.minimumPaintedAlpha(windowOpacity: 1) == 247)
        #expect(AdaptiveTerminalBackgroundDetector.minimumPaintedAlpha(windowOpacity: 0.864) == 212)
        // Even a fully transparent window keeps unpainted (alpha 0) pixels out:
        // the floor clamps at 0 and the scan itself excludes them.
        #expect(AdaptiveTerminalBackgroundDetector.minimumPaintedAlpha(windowOpacity: 0) == 0)
        let unpainted = Array(repeating: pixel(40, 40, 40, 0), count: 100)
        #expect(
            AdaptiveTerminalBackgroundDetector.dominantColor(
                in: unpainted,
                minimumAlpha: AdaptiveTerminalBackgroundDetector.minimumPaintedAlpha(windowOpacity: 0)
            ) == nil
        )
    }

    @Test
    func onlyOpaquePaintGetsAPaneFill() throws {
        let opaque = NSColor(srgbRed: 0.2, green: 0.1, blue: 0.3, alpha: 1)
        let translucent = opaque.withAlphaComponent(0.864)

        let fill = try #require(AdaptiveTerminalChrome.paneFill(opaque))
        #expect(fill.isVisuallyEqual(to: opaque))
        // The renderer already painted this one at the window opacity; a solid
        // fill behind it would make the pane the only opaque thing on screen.
        #expect(AdaptiveTerminalChrome.paneFill(translucent) == nil)
    }

    @Test
    func samplingBurstStopsAfterItsRequestedRetries() {
        var burst = AdaptiveTerminalSamplingBurst()

        burst.request(retries: 2)
        let firstRetry = burst.consumeRetry()
        let secondRetry = burst.consumeRetry()
        let exhausted = burst.consumeRetry()

        #expect(firstRetry)
        #expect(secondRetry)
        #expect(!exhausted)
    }

    @Test
    func samplingBurstExtendsWithoutAccumulatingForever() {
        var burst = AdaptiveTerminalSamplingBurst()
        burst.request(retries: 3)
        let firstRetry = burst.consumeRetry()

        burst.request(retries: 2)

        #expect(firstRetry)
        #expect(burst.retriesRemaining == 2)
        burst.cancel()
        let retryAfterCancellation = burst.consumeRetry()
        #expect(!retryAfterCancellation)
    }

    @Test
    func samplesGhosttyBGRAIOSurface() throws {
        let properties = [
            kIOSurfaceWidth: NSNumber(value: 40),
            kIOSurfaceHeight: NSNumber(value: 30),
            kIOSurfaceBytesPerElement: NSNumber(value: 4),
            kIOSurfacePixelFormat: NSNumber(value: kCVPixelFormatType_32BGRA),
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
    func reportsWherePaintSitsSoTheBackdropCanBeCutUnderItButNotUnderThePadding() throws {
        // A TUI painting the middle of the frame at the window opacity, with an
        // unpainted margin standing in for the window padding. The reported
        // bounds have to stay inside the paint: the caller cuts its own tinted
        // backdrop there, and cutting past the paint would strand the padding
        // on a bare desktop.
        let width = 200
        let height = 100
        let paintedRange = (x: 60 ..< 140, y: 30 ..< 70)
        let properties = [
            kIOSurfaceWidth: NSNumber(value: width),
            kIOSurfaceHeight: NSNumber(value: height),
            kIOSurfaceBytesPerElement: NSNumber(value: 4),
            kIOSurfacePixelFormat: NSNumber(value: kCVPixelFormatType_32BGRA),
        ] as CFDictionary
        let surface = try #require(IOSurfaceCreate(properties))
        var seed: UInt32 = 0
        #expect(IOSurfaceLock(surface, [], &seed) == kIOReturnSuccess)
        let base = IOSurfaceGetBaseAddress(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = y * bytesPerRow + x * 4
                let painted = paintedRange.x.contains(x) && paintedRange.y.contains(y)
                // Premultiplied: (40, 30, 20) at alpha 229.
                base.storeBytes(of: UInt8(painted ? 18 : 0), toByteOffset: offset, as: UInt8.self)
                base.storeBytes(of: UInt8(painted ? 27 : 0), toByteOffset: offset + 1, as: UInt8.self)
                base.storeBytes(of: UInt8(painted ? 36 : 0), toByteOffset: offset + 2, as: UInt8.self)
                base.storeBytes(of: UInt8(painted ? 229 : 0), toByteOffset: offset + 3, as: UInt8.self)
            }
        }
        #expect(IOSurfaceUnlock(surface, [], &seed) == kIOReturnSuccess)

        let match = try #require(
            AdaptiveTerminalBackgroundDetector.dominantColor(
                in: surface,
                // Coverage is only the painted middle, so the frame-wide
                // default would reject it; this test is about the geometry.
                minimumCoverage: 0.1,
                minimumAlpha: AdaptiveTerminalBackgroundDetector.minimumPaintedAlpha(windowOpacity: 0.9)
            )
        )
        let bounds = try #require(match.paintedUnitBounds)
        let painted = CGRect(x: 60.0 / 200, y: 30.0 / 100, width: 80.0 / 200, height: 40.0 / 100)
        #expect(painted.contains(bounds.insetBy(dx: 0.0001, dy: 0.0001)) || painted.intersects(bounds))
        // Inside the paint on every edge, and covering most of it.
        #expect(bounds.minX >= painted.minX)
        #expect(bounds.minY >= painted.minY)
        #expect(bounds.maxX <= painted.maxX)
        #expect(bounds.maxY <= painted.maxY)
        #expect(bounds.width >= painted.width * 0.7)
        #expect(bounds.height >= painted.height * 0.7)
    }

    @Test
    func rejectsIOSurfaceWithUnexpectedPixelFormat() throws {
        let properties = [
            kIOSurfaceWidth: NSNumber(value: 40),
            kIOSurfaceHeight: NSNumber(value: 30),
            kIOSurfaceBytesPerElement: NSNumber(value: 4),
            kIOSurfacePixelFormat: NSNumber(value: kCVPixelFormatType_32RGBA),
        ] as CFDictionary
        let surface = try #require(IOSurfaceCreate(properties))

        #expect(AdaptiveTerminalBackgroundDetector.dominantColor(in: surface) == nil)
    }

    @Test
    func configuredBackgroundIsSuppressedAsAnAdaptiveCandidate() throws {
        let configured = NSColor(srgbRed: 0.10, green: 0.20, blue: 0.30, alpha: 1)
        let near = NSColor(srgbRed: 0.11, green: 0.20, blue: 0.30, alpha: 1)
        let distinct = NSColor(srgbRed: 0.55, green: 0.20, blue: 0.30, alpha: 1)

        #expect(AdaptiveTerminalChrome.effectiveCandidate(nil, configuredBackground: configured) == nil)
        #expect(AdaptiveTerminalChrome.effectiveCandidate(near, configuredBackground: configured) == nil)
        let candidate = try #require(
            AdaptiveTerminalChrome.effectiveCandidate(distinct, configuredBackground: configured)
        )
        #expect(candidate.isVisuallyEqual(to: distinct))
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

    // MARK: - Inference gate

    private func allows(
        color: Bool = true,
        overlay: Bool = false,
        confirmed: Bool = true,
        sinceOutput: TimeInterval? = nil
    ) -> Bool {
        AdaptiveTerminalInferenceGate.allowsObservation(
            ofColor: color,
            hasViewerOverlay: overlay,
            hasConfirmedColor: confirmed,
            secondsSinceOutput: sinceOutput
        )
    }

    @Test
    func aViewerOverlayBlocksInferenceOutrightSoASelectionCannotBeAdopted() {
        // The drag case: a selection covers most of the frame and arrives as an
        // ordinary cell background, so only the overlay predicate can reject it.
        #expect(allows(overlay: true, sinceOutput: 0) == false)
        #expect(allows(overlay: true, confirmed: false, sinceOutput: 0) == false)
    }

    @Test
    func aViewerOverlayBlocksClearingTooSoThePaneFreezesRatherThanFlashing() {
        #expect(allows(color: false, overlay: true, sinceOutput: 0) == false)
    }

    @Test
    func aConfirmedColorIsProtectedFromOutputFreeRepaints() {
        #expect(allows(sinceOutput: nil) == false)
        #expect(allows(sinceOutput: AdaptiveTerminalInferenceGate.outputRecencyWindow + 0.5) == false)
    }

    @Test
    func recentOutputLetsAConfirmedColorChange() {
        #expect(allows(sinceOutput: 0))
        #expect(allows(sinceOutput: AdaptiveTerminalInferenceGate.outputRecencyWindow))
    }

    @Test
    func aPaneWithNothingToProtectStillAdoptsItsFirstColorWithoutRecentOutput() {
        // A quiet TUI already on screen when the preference is switched on has
        // no output to point at; the overlay predicate is what keeps this safe.
        #expect(allows(confirmed: false, sinceOutput: nil))
    }

    @Test
    func clearingIsNeverGatedOnOutputSoAnOffScreenExitStillFallsBack() {
        // A TUI that exits inside an occluded tab is only observed on the way
        // back, long after its last output. Falling back to the configured
        // theme is always a valid presentation, so causality guards adoption
        // only.
        #expect(allows(color: false, sinceOutput: nil))
        #expect(allows(color: false, sinceOutput: 600))
    }

    @Test
    func stabilizerReportsWhetherAColorIsTheConfirmedPresentation() {
        var stabilizer = AdaptiveTerminalBackgroundStabilizer()
        #expect(stabilizer.hasConfirmedColor == false)

        let color = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        #expect(stabilizer.observe(color) == nil)
        #expect(stabilizer.hasConfirmedColor == false)
        #expect(stabilizer.observe(color) == .applyColor)
        #expect(stabilizer.hasConfirmedColor)

        #expect(stabilizer.observe(nil) == nil)
        #expect(stabilizer.observe(nil) == .clear)
        #expect(stabilizer.hasConfirmedColor == false)
    }
}
