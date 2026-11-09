import AppKit
import GhosttyKit
import IOSurface

/// Measures in-app typing latency for the benchmark (`pane.latency`): the time
/// from `sendKey` (the `pane key` path) to the first rendered frame that shows
/// the typed glyph in the cursor's cell.
///
/// The probe reads the pane's IOSurface, as `PanePreviewCapture` does. The
/// renderer sets the layer's contents on the main thread, so a poll on the
/// main actor sees each frame when it lands, late by up to one poll and the
/// main-queue delay. `Task.sleep` coalesces short sleeps, so the poll gap is
/// not measured here; it is the same for every build that we compare.
///
/// The glyph frame is not "the first frame that changed": a cursor blink also
/// changes the cell. It is the first frame whose cell is the same as the cell
/// at the end of the window, because after the key the cursor is in the next
/// cell and the glyph stays.
///
/// Not measured: `keyDown`, and the display compositor after the frame.
/// The benchmark's hermetic run has no smooth cursor, no cursor trail and a
/// shell with no syntax highlighting; each of them would move the final frame.
@MainActor
enum TypingLatencyProbe {
    struct Result: Equatable {
        /// Milliseconds from the key to the glyph frame, one for each key.
        var samples: [Double]
        /// Keys with no glyph in the window.
        var misses: Int
    }

    struct Observation: Equatable {
        var seconds: Double
        var cell: Data
    }

    static let pollInterval: Duration = .microseconds(500)
    /// How long each key is watched. The last frame in it is the glyph frame.
    static let window: Duration = .milliseconds(300)
    /// The wait after the line is cleared, before the next key.
    static let settle: Duration = .milliseconds(150)

    /// The time of the first observation that shows the final cell, or nil
    /// when the cell never left `before`.
    nonisolated static func glyphTime(before: Data, observations: [Observation]) -> Double? {
        guard let final = observations.last?.cell, final != before else { return nil }
        return observations.first { $0.cell == final }?.seconds
    }

    /// The cursor's cell in view points (bottom-left origin) from the IME
    /// point. libghostty puts the point's x at the MIDDLE of the cell and its
    /// y at the cell's BOTTOM edge, measured from the top of the view; the
    /// point's own width is the preedit's, so the cell width comes from the
    /// surface size. (`cursorCellRect` keeps its own shape for its callers.)
    nonisolated static func cursorCell(
        imeX: Double, imeY: Double, height: Double, cellWidth: Double, boundsHeight: Double
    ) -> NSRect? {
        guard height > 0, cellWidth > 0 else { return nil }
        return NSRect(x: imeX - cellWidth / 2, y: boundsHeight - imeY, width: cellWidth, height: height)
    }

    private static func cursorCell(of view: GhosttyTerminalNSView) -> NSRect? {
        guard let surface = view.surface, let size = view.surfaceSize else { return nil }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        // The same scale as the pixel read in `cell(of:in:)`.
        guard let frame = view.layer?.contents as? IOSurface, view.bounds.width > 0 else { return nil }
        let scale = Double(IOSurfaceGetWidth(frame)) / view.bounds.width
        return cursorCell(
            imeX: x, imeY: y, height: h,
            cellWidth: Double(size.cell_width_px) / scale,
            boundsHeight: view.bounds.height
        )
    }

    /// Type `key` `count` times into `view`, each time clearing the line
    /// with `clear` after the window. A key that cannot be sent counts as a
    /// miss.
    static func measure(
        view: GhosttyTerminalNSView,
        key: HotkeyShortcut,
        clear: HotkeyShortcut,
        count: Int
    ) async -> Result {
        var result = Result(samples: [], misses: 0)
        for _ in 0 ..< count {
            guard let rect = cursorCell(of: view),
                  let before = cell(of: view, in: rect)
            else {
                result.misses += 1
                try? await Task.sleep(for: settle)
                continue
            }
            let clock = ContinuousClock()
            let start = clock.now
            guard view.sendKey(keyCode: key.keyCode, mods: key.modifiers) else {
                result.misses += 1
                try? await Task.sleep(for: settle)
                continue
            }
            var observations: [Observation] = []
            var lastFrame: (IOSurfaceID, UInt32)?
            while clock.now - start < window {
                try? await Task.sleep(for: pollInterval)
                guard let surface = view.layer?.contents as? IOSurface else { continue }
                let frame = (IOSurfaceGetID(surface), IOSurfaceGetSeed(surface))
                if let lastFrame, lastFrame == frame { continue }
                lastFrame = frame
                guard let pixels = cell(of: view, in: rect) else { continue }
                let elapsed = clock.now - start
                observations.append(Observation(seconds: seconds(elapsed), cell: pixels))
            }
            if let time = glyphTime(before: before, observations: observations) {
                result.samples.append(time * 1000)
            } else {
                result.misses += 1
            }
            _ = view.sendKey(keyCode: clear.keyCode, mods: clear.modifiers)
            try? await Task.sleep(for: settle)
        }
        return result
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// The bytes of `rect` (view points, bottom-left origin) in the current
    /// frame, or nil when the frame is not the BGRA layout we know. Fails
    /// closed, as `PanePreviewCapture` does.
    private static func cell(of view: GhosttyTerminalNSView, in rect: NSRect) -> Data? {
        guard let surface = view.layer?.contents as? IOSurface, view.bounds.width > 0 else { return nil }
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0,
              IOSurfaceGetPixelFormat(surface) == kCVPixelFormatType_32BGRA,
              IOSurfaceGetBytesPerElement(surface) == 4
        else { return nil }
        let scale = CGFloat(width) / view.bounds.width
        let x0 = max(0, Int((rect.minX * scale).rounded(.up)))
        let x1 = min(width, Int((rect.maxX * scale).rounded(.down)))
        let y0 = max(0, Int(((view.bounds.height - rect.maxY) * scale).rounded(.up)))
        let y1 = min(height, Int(((view.bounds.height - rect.minY) * scale).rounded(.down)))
        guard x1 > x0, y1 > y0 else { return nil }

        var seed: UInt32 = 0
        guard IOSurfaceLock(surface, [.readOnly], &seed) == kIOReturnSuccess else { return nil }
        defer { IOSurfaceUnlock(surface, [.readOnly], &seed) }
        let base = IOSurfaceGetBaseAddress(surface)
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        var data = Data(capacity: (x1 - x0) * 4 * (y1 - y0))
        for row in y0 ..< y1 {
            data.append(base.advanced(by: row * bytesPerRow + x0 * 4).assumingMemoryBound(to: UInt8.self), count: (x1 - x0) * 4)
        }
        return data
    }
}
