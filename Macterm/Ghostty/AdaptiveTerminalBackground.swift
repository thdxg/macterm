import AppKit
import CoreVideo
import IOSurface

/// Detects a flat background painted across most of a terminal frame.
/// Unpainted theme pixels remain part of the denominator, so ordinary shell
/// content cannot win merely because its handful of glyph pixels are painted.
///
/// "Painted" is not the same as "opaque": with the user's own
/// `background-opacity-cells`, ghostty writes explicitly-painted cells at
/// `background-opacity * 255` (`renderer/generic.zig`), so a full-screen TUI
/// background arrives at the window opacity, not at 255 — while cells carrying
/// the *default* background are still not painted at all (alpha 0, the
/// `background-default-transparent` contract). The two remain trivially
/// separable; the threshold just has to follow the opacity instead of assuming
/// 255. The surface is premultiplied (`renderer/metal/Pipeline.zig`), so those
/// pixels also have to be divided back out before their color means anything.
///
/// Winning the color vote is necessary but not sufficient: the winner must
/// also reach across the grid, or it is content painted *on* a background
/// rather than the background. See `minimumBackgroundExtent`.
enum AdaptiveTerminalBackgroundDetector {
    struct Pixel: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    struct Match: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
        let coverage: Double
        /// Where the painted color actually sits in the frame, as fractions of
        /// the sampled surface with a top-left origin. Nil when sampled from a
        /// bare pixel list with no geometry. The renderer paints only cells, so
        /// this excludes the window padding — which is what lets a caller
        /// suppress its own backdrop under the paint without stranding the
        /// padding on a bare desktop.
        var paintedUnitBounds: CGRect?

        /// The winning color's *own* footprint, as fractions of the sampled
        /// grid with a top-left origin — the signal that separates a
        /// background from something drawn on one. Nil when sampled from a
        /// bare pixel list with no geometry.
        ///
        /// Distinct from `paintedUnitBounds`, which is every painted pixel
        /// regardless of color, walked out to the real edge in surface
        /// coordinates because a caller cuts its backdrop to it.
        var dominantUnitBounds: CGRect?

        /// The painted color, carrying the alpha it was painted at. Consumers
        /// that need the pure hue (the window tint, which is composited at the
        /// window opacity in its own right) take `withAlphaComponent(1)`.
        ///
        /// `space` is the renderer's own color space: these are its numbers, so
        /// labelling them sRGB when it paints in Display P3 shifts the color by
        /// a couple of counts per channel — enough to see where a pane's paint
        /// meets the chrome tint that is supposed to match it.
        func color(in space: NSColorSpace? = nil) -> NSColor {
            let components: [CGFloat] = [
                CGFloat(red) / 255,
                CGFloat(green) / 255,
                CGFloat(blue) / 255,
                CGFloat(alpha) / 255,
            ]
            guard let space, space.numberOfColorComponents == 3, space.colorSpaceModel == .rgb else {
                return NSColor(
                    srgbRed: components[0],
                    green: components[1],
                    blue: components[2],
                    alpha: components[3]
                )
            }
            return NSColor(colorSpace: space, components: components, count: 4)
        }
    }

    private struct SampledColor: Hashable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8

        init(_ pixel: Pixel) {
            red = pixel.red
            green = pixel.green
            blue = pixel.blue
        }

        var packedValue: UInt32 {
            UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
        }
    }

    private struct Bucket {
        var count = 0
        var red = 0
        var green = 0
        var blue = 0
        var alpha = 0
        var frequencies: [SampledColor: Int] = [:]

        mutating func add(_ pixel: Pixel) {
            count += 1
            red += Int(pixel.red)
            green += Int(pixel.green)
            blue += Int(pixel.blue)
            alpha += Int(pixel.alpha)
            frequencies[SampledColor(pixel), default: 0] += 1
        }

        /// The alpha the winning color was painted at, which decides whether
        /// the pane needs an opaque fill behind it or is already carrying the
        /// window's translucency itself.
        var representativeAlpha: UInt8 {
            guard !frequencies.isEmpty else { return 255 }
            return UInt8(clamping: Int((Double(alpha) / Double(count)).rounded()))
        }

        /// Prefer the exact mode. When renderer variance makes several colors
        /// equally frequent, choose the sampled color nearest the bucket mean.
        var representativeColor: SampledColor? {
            guard !frequencies.isEmpty else { return nil }
            let meanRed = Double(red) / Double(count)
            let meanGreen = Double(green) / Double(count)
            let meanBlue = Double(blue) / Double(count)

            func squaredDistance(_ color: SampledColor) -> Double {
                let redDelta = Double(color.red) - meanRed
                let greenDelta = Double(color.green) - meanGreen
                let blueDelta = Double(color.blue) - meanBlue
                return redDelta * redDelta + greenDelta * greenDelta + blueDelta * blueDelta
            }

            return frequencies.keys.min { lhs, rhs in
                let lhsFrequency = frequencies[lhs, default: 0]
                let rhsFrequency = frequencies[rhs, default: 0]
                if lhsFrequency != rhsFrequency { return lhsFrequency > rhsFrequency }

                let lhsDistance = squaredDistance(lhs)
                let rhsDistance = squaredDistance(rhs)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                return lhs.packedValue < rhs.packedValue
            }
        }
    }

    /// The lowest alpha that still counts as a painted cell for a window at
    /// `windowOpacity`. Macterm forces `background-opacity = windowOpacity`,
    /// so a painted cell arrives at either 255 (the default) or
    /// `@intFromFloat(255 * opacity)` (the user's `background-opacity-cells`);
    /// an unpainted one is always exactly 0. The floor tracks the lower of the
    /// two with a little slack for renderer rounding, which keeps both cases
    /// in and every unpainted pixel out.
    static func minimumPaintedAlpha(windowOpacity: Double) -> UInt8 {
        let painted = (255 * max(0, min(1, windowOpacity))).rounded(.down)
        return UInt8(clamping: Int(painted) - 8)
    }

    /// The share of the sampled grid a color has to reach across, in each axis
    /// independently, before it counts as a *background* rather than as
    /// something drawn on one.
    ///
    /// Coverage alone cannot tell those apart. A slide, a rendered image or a
    /// program-drawn selection block arrives as ordinary painted cells and can
    /// easily hold the majority of a frame while the terminal's real background
    /// is the unpainted default all around it — which is what made a white
    /// slide filling the middle of a Helix pane repaint the whole window white.
    /// Geometry does tell them apart, from inside the frame and with no timing,
    /// ABI or mouse state involved: a background reaches across the grid,
    /// whereas content is bounded by content.
    ///
    /// The threshold is deliberately loose in both directions. Above it stay
    /// the shapes real TUIs draw — a full-bleed background with a differently
    /// colored tab bar, status line or both still spans ~0.96 of its axis —
    /// and the color vote's own 5%-per-side edge inset doubles as an allowance
    /// for `window-padding`, which is unpainted under the default
    /// `window-padding-color = background`. Below it stay content blocks, which
    /// have to leave a fifth of an axis to the terminal's own background to be
    /// rejected. The known edge is padding larger than about 5% of a small
    /// pane's short side: that reads as a block and falls back to the
    /// configured theme, which is a safe presentation rather than a wrong one.
    static let minimumBackgroundExtent: Double = 0.80

    /// Whether a color's own footprint behaves like a background: reaching
    /// across the sampled grid in *both* axes.
    ///
    /// Judged per axis rather than by area, because "reaches across the grid"
    /// is an each-axis claim and area lets a surplus in one axis pay for a
    /// deficit in the other — a full-width band buys back most of the height it
    /// is missing, until it scores the same as a genuine background sitting
    /// inside generous padding.
    static func spansLikeBackground(
        _ bounds: CGRect,
        minimumExtent: Double = minimumBackgroundExtent
    ) -> Bool {
        Double(bounds.width) >= minimumExtent && Double(bounds.height) >= minimumExtent
    }

    /// Four bits per component absorb tiny renderer/color-space differences
    /// without merging visibly distinct backgrounds.
    private static func bucketKey(_ pixel: Pixel) -> Int {
        Int(pixel.red >> 4) << 8 | Int(pixel.green >> 4) << 4 | Int(pixel.blue >> 4)
    }

    private static func isPainted(_ pixel: Pixel, minimumAlpha: UInt8) -> Bool {
        pixel.alpha >= minimumAlpha && pixel.alpha > 0
    }

    static func dominantColor(
        in pixels: [Pixel],
        minimumCoverage: Double = 0.60,
        minimumAlpha: UInt8 = 230
    ) -> Match? {
        vote(in: pixels, minimumCoverage: minimumCoverage, minimumAlpha: minimumAlpha)?.match
    }

    /// The color vote, plus the bucket that won it so a caller holding the
    /// samples' geometry can ask where that color actually sits.
    private struct Vote {
        let match: Match
        let bucketKey: Int
    }

    private static func vote(
        in pixels: [Pixel],
        minimumCoverage: Double,
        minimumAlpha: UInt8
    ) -> Vote? {
        guard !pixels.isEmpty else { return nil }

        var buckets: [Int: Bucket] = [:]
        for pixel in pixels where isPainted(pixel, minimumAlpha: minimumAlpha) {
            let straightened = straightened(pixel)
            let key = bucketKey(straightened)
            var bucket = buckets[key, default: Bucket()]
            bucket.add(straightened)
            buckets[key] = bucket
        }

        // Ties break on the lower key rather than on dictionary order, so the
        // winning bucket — and therefore the geometry gate that reads it — is
        // the same for the same frame every time.
        let winner = buckets.min { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
            return lhs.key < rhs.key
        }
        guard let winner else { return nil }
        let coverage = Double(winner.value.count) / Double(pixels.count)
        guard coverage >= minimumCoverage,
              let representative = winner.value.representativeColor
        else { return nil }

        return Vote(
            match: Match(
                red: representative.red,
                green: representative.green,
                blue: representative.blue,
                alpha: winner.value.representativeAlpha,
                coverage: coverage
            ),
            bucketKey: winner.key
        )
    }

    /// Where the winning color sits within the sampled grid, in unit
    /// coordinates with a top-left origin. Measured in sample-index space: the
    /// grid is uniform, so index spans and pixel spans give the same fractions,
    /// and indices cannot degenerate to a zero-width denominator.
    private static func dominantUnitBounds(
        ofBucket key: Int,
        samples: [Pixel],
        columns: Int,
        rows: Int,
        minimumAlpha: UInt8
    ) -> CGRect? {
        guard columns > 0, rows > 0 else { return nil }
        var minColumn = Int.max, maxColumn = Int.min
        var minRow = Int.max, maxRow = Int.min
        for (index, pixel) in samples.enumerated()
            where isPainted(pixel, minimumAlpha: minimumAlpha)
            && bucketKey(straightened(pixel)) == key
        {
            let column = index % columns
            let row = index / columns
            minColumn = min(minColumn, column)
            maxColumn = max(maxColumn, column)
            minRow = min(minRow, row)
            maxRow = max(maxRow, row)
        }
        guard minColumn <= maxColumn, minRow <= maxRow else { return nil }
        return CGRect(
            x: CGFloat(minColumn) / CGFloat(columns),
            y: CGFloat(minRow) / CGFloat(rows),
            width: CGFloat(maxColumn - minColumn + 1) / CGFloat(columns),
            height: CGFloat(maxRow - minRow + 1) / CGFloat(rows)
        )
    }

    /// Divide out the premultiplied alpha so a cell painted at the window
    /// opacity reports the color the TUI actually asked for, not that color
    /// scaled toward black.
    private static func straightened(_ pixel: Pixel) -> Pixel {
        guard pixel.alpha > 0, pixel.alpha < 255 else { return pixel }
        let scale = 255 / Double(pixel.alpha)
        func straighten(_ component: UInt8) -> UInt8 {
            UInt8(clamping: Int((Double(component) * scale).rounded()))
        }
        return Pixel(
            red: straighten(pixel.red),
            green: straighten(pixel.green),
            blue: straighten(pixel.blue),
            alpha: pixel.alpha
        )
    }

    /// Sample a bounded grid rather than scanning every backing pixel. The
    /// current renderer uses BGRA8; fail closed if that private implementation
    /// detail changes instead of interpreting an unfamiliar layout.
    static func dominantColor(
        in surface: IOSurface,
        minimumCoverage: Double = 0.60,
        minimumExtent: Double = minimumBackgroundExtent,
        minimumAlpha: UInt8 = 230
    ) -> Match? {
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let bytesPerElement = IOSurfaceGetBytesPerElement(surface)
        guard IOSurfaceGetPixelFormat(surface) == kCVPixelFormatType_32BGRA,
              width > 0,
              height > 0,
              bytesPerElement == 4
        else { return nil }

        let (minimumBytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: bytesPerElement)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        let (minimumAllocation, allocationOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow,
              !allocationOverflow,
              bytesPerRow >= minimumBytesPerRow,
              IOSurfaceGetAllocSize(surface) >= minimumAllocation
        else { return nil }

        var seed: UInt32 = 0
        guard IOSurfaceLock(surface, [.readOnly], &seed) == kIOReturnSuccess else { return nil }
        defer { IOSurfaceUnlock(surface, [.readOnly], &seed) }

        let base = IOSurfaceGetBaseAddress(surface)
        let xStep = max(1, width / 80)
        let yStep = max(1, height / 50)
        let xInset = min(width / 20, xStep * 2)
        let yInset = min(height / 20, yStep * 2)
        guard width > xInset * 2, height > yInset * 2 else { return nil }

        // Materialized so the sample list has a known row-major shape: a
        // sample's index alone then locates it in the grid, which is what the
        // geometry gate below reads.
        let columns = Array(stride(from: xInset + xStep / 2, to: width - xInset, by: xStep))
        let rows = Array(stride(from: yInset + yStep / 2, to: height - yInset, by: yStep))
        guard !columns.isEmpty, !rows.isEmpty else { return nil }

        var pixels: [Pixel] = []
        var positions: [(x: Int, y: Int)] = []
        pixels.reserveCapacity(rows.count * columns.count)
        positions.reserveCapacity(rows.count * columns.count)
        for y in rows {
            for x in columns {
                let offset = y * bytesPerRow + x * bytesPerElement
                let blue = base.load(fromByteOffset: offset, as: UInt8.self)
                let green = base.load(fromByteOffset: offset + 1, as: UInt8.self)
                let red = base.load(fromByteOffset: offset + 2, as: UInt8.self)
                let alpha = base.load(fromByteOffset: offset + 3, as: UInt8.self)
                pixels.append(Pixel(red: red, green: green, blue: blue, alpha: alpha))
                positions.append((x: x, y: y))
            }
        }
        guard let vote = vote(
            in: pixels,
            minimumCoverage: minimumCoverage,
            minimumAlpha: minimumAlpha
        )
        else { return nil }
        // A color that won the vote without reaching across the grid is
        // content sitting on the terminal's background, not the background —
        // so there is nothing to adopt and the configured theme, which is what
        // the unpainted cells around it are showing, stays the presentation.
        guard let dominantBounds = dominantUnitBounds(
            ofBucket: vote.bucketKey,
            samples: pixels,
            columns: columns.count,
            rows: rows.count,
            minimumAlpha: minimumAlpha
        ),
            spansLikeBackground(dominantBounds, minimumExtent: minimumExtent)
        else { return nil }

        var match = vote.match
        match.dominantUnitBounds = dominantBounds
        match.paintedUnitBounds = paintedUnitBounds(
            samples: (pixels: pixels, positions: positions),
            minimumAlpha: minimumAlpha,
            reader: PixelReader(
                base: base,
                bytesPerRow: bytesPerRow,
                bytesPerElement: bytesPerElement,
                width: width,
                height: height
            )
        )
        return match
    }

    /// Random access to the locked surface, so the painted region's edge can be
    /// refined pixel by pixel instead of being guessed from the coarse grid.
    private struct PixelReader {
        let base: UnsafeMutableRawPointer
        let bytesPerRow: Int
        let bytesPerElement: Int
        let width: Int
        let height: Int

        func alpha(x: Int, y: Int) -> UInt8 {
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            return base.load(fromByteOffset: y * bytesPerRow + x * bytesPerElement + 3, as: UInt8.self)
        }
    }

    /// The region the terminal is painting, in unit coordinates with a
    /// top-left origin.
    ///
    /// Judged by alpha, not by color: every explicitly-painted cell already
    /// carries the window opacity, whatever its color, and it is the *paint*
    /// that the caller's own backdrop must not sit under. An unpainted cell is
    /// alpha 0 (`background-default-transparent`), so the test is unambiguous.
    ///
    /// The coarse grid only locates the region — its 5% edge inset, there to
    /// keep edge artifacts out of the color vote, would otherwise stop the
    /// bounds ~5% short of the real edge, and a caller cutting its tint to
    /// those bounds leaves a ring where cells and tint both paint: exactly the
    /// solid frame that gives the mismatch away. So each edge is then walked
    /// outward a pixel at a time to where the paint actually stops.
    private static func paintedUnitBounds(
        samples: (pixels: [Pixel], positions: [(x: Int, y: Int)]),
        minimumAlpha: UInt8,
        reader: PixelReader
    ) -> CGRect? {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for (index, pixel) in samples.pixels.enumerated()
            where pixel.alpha >= minimumAlpha && pixel.alpha > 0
        {
            let position = samples.positions[index]
            minX = min(minX, position.x)
            minY = min(minY, position.y)
            maxX = max(maxX, position.x)
            maxY = max(maxY, position.y)
        }
        guard minX <= maxX, minY <= maxY, reader.width > 0, reader.height > 0 else { return nil }

        func isPainted(x: Int, y: Int) -> Bool {
            let alpha = reader.alpha(x: x, y: y)
            return alpha >= minimumAlpha && alpha > 0
        }

        // Walk from a mid-edge sample, which is inside the paint by
        // construction, out to the last painted pixel.
        let midY = (minY + maxY) / 2
        let midX = (minX + maxX) / 2
        var left = minX, right = maxX, top = minY, bottom = maxY
        while left > 0, isPainted(x: left - 1, y: midY) {
            left -= 1
        }
        while right < reader.width - 1, isPainted(x: right + 1, y: midY) {
            right += 1
        }
        while top > 0, isPainted(x: midX, y: top - 1) {
            top -= 1
        }
        while bottom < reader.height - 1, isPainted(x: midX, y: bottom + 1) {
            bottom += 1
        }

        return CGRect(
            x: CGFloat(left) / CGFloat(reader.width),
            y: CGFloat(top) / CGFloat(reader.height),
            width: CGFloat(right - left + 1) / CGFloat(reader.width),
            height: CGFloat(bottom - top + 1) / CGFloat(reader.height)
        )
    }
}

/// Rejects single-frame color changes in either direction. Entering a TUI,
/// leaving it, and changing between two full-screen colors all require two
/// matching observations, preventing chrome flashes during redraws.
struct AdaptiveTerminalBackgroundStabilizer {
    enum Change: Equatable {
        case applyColor
        case clear
    }

    private enum Token: Equatable {
        case clear
        case color(red: UInt8, green: UInt8, blue: UInt8)

        init(_ color: NSColor?) {
            guard let rgb = color?.usingColorSpace(.sRGB) else {
                self = .clear
                return
            }
            func quantize(_ component: CGFloat) -> UInt8 {
                UInt8((max(0, min(1, component)) * 31).rounded())
            }
            self = .color(
                red: quantize(rgb.redComponent),
                green: quantize(rgb.greenComponent),
                blue: quantize(rgb.blueComponent)
            )
        }
    }

    private var current: Token = .clear
    private var pending: Token?

    init() {}

    /// Start from a previously confirmed color (e.g. remembered across a
    /// pane's occlusion) so re-observing it is a no-op rather than a change.
    init(seededWith color: NSColor?) {
        current = Token(color)
    }

    var hasPendingObservation: Bool { pending != nil }

    /// Whether a color — as opposed to the configured theme — is the confirmed
    /// presentation. The inference gate protects a confirmed color from
    /// output-free repaints while leaving a pane that has nothing to protect
    /// free to adopt its first one.
    var hasConfirmedColor: Bool { current != .clear }

    mutating func reset(to color: NSColor?) {
        current = Token(color)
        pending = nil
    }

    mutating func observe(_ color: NSColor?) -> Change? {
        let observed = Token(color)
        guard observed != current else {
            pending = nil
            return nil
        }
        guard pending == observed else {
            pending = observed
            return nil
        }

        current = observed
        pending = nil
        return color == nil ? .clear : .applyColor
    }
}

/// Decides whether an inferred (IOSurface-sampled) observation may reach the
/// stabilizer at all.
///
/// The sampled frame is a *composite*: cells the terminal painted plus whatever
/// the viewer drew over them. A selection highlight arrives as an ordinary cell
/// background at the same opacity a TUI's own paint gets, so no statistic over
/// the pixels — coverage, alpha, geometry — can separate the two. The
/// distinction is provenance, and it has to come from outside the frame.
///
/// Two independent signals carry it, and each covers the other's gap:
///
/// - **The overlay predicate** is exact: libghostty answers
///   `ghostty_surface_has_selection` about the very state that dirtied the
///   frame. A frame carrying an overlay is not a faithful render of the screen
///   model, so nothing is inferred from it — the pane freezes on its last
///   confirmed presentation rather than clearing, because the screen model
///   itself did not change.
/// - **Output causality** is the backstop for overlays with no such predicate:
///   a terminal background only ever changes because the program wrote to the
///   pty, while a viewer repaint involves no output at all.
///
/// Causality guards *adoption* only, never *clearing*. Falling back to the
/// configured theme is always a valid presentation, whereas adopting a color
/// the terminal never painted is not — and the asymmetry is also what keeps a
/// TUI that exits inside an occluded tab clearing on the way back, long after
/// its last output. It likewise never blocks a pane's first adoption: a quiet
/// TUI already on screen when the preference was switched on has no recent
/// output to point at, and the overlay predicate is what keeps that opening
/// safe.
enum AdaptiveTerminalInferenceGate {
    /// How long after a pty output heartbeat a frame is still attributable to
    /// it. The heartbeat is throttled to 500ms leading-edge and each one arms a
    /// burst that samples at +0.12s with retries to ~+0.62s, so this covers a
    /// whole burst plus slack for Metal publishing the finished frame — while
    /// staying far shorter than any drag a hand can hold.
    static let outputRecencyWindow: TimeInterval = 1.5

    static func allowsObservation(
        ofColor isColor: Bool,
        hasViewerOverlay: Bool,
        hasConfirmedColor: Bool,
        secondsSinceOutput: TimeInterval?
    ) -> Bool {
        if hasViewerOverlay { return false }
        guard isColor, hasConfirmedColor else { return true }
        guard let secondsSinceOutput else { return false }
        return secondsSinceOutput <= outputRecencyWindow
    }
}
