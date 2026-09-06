import AppKit
import CoreGraphics
import IOSurface
import os

private let logger = Logger(subsystem: appBundleID, category: "PanePreview")

/// A frozen visual snapshot of one pane's contents, cheap enough to render in
/// a transient overlay (the tab switcher) and stable enough that the overlay
/// doesn't re-sample per frame.
///
/// Two sources, in order of fidelity:
///
/// - **The rendered frame.** ghostty's surface layer is an `IOSurfaceLayer`
///   whose `contents` is the last frame it drew (the same handle
///   `AdaptiveTerminalChrome` samples for the adaptive background), so a real
///   thumbnail needs no renderer of our own — just a downsampled copy.
///
///   **Only a pane that is currently on screen has one.** Measured: an
///   inactive tab's panes keep their NSView (it is pane-owned, warmed by
///   `SurfaceIncubator`) but their `layer.contents` is nil — ghostty does not
///   leave a frame parked in an occluded surface. So a switcher cannot sample
///   the tabs it is offering; the frames have to be collected *while* each tab
///   is visible and remembered. That is what `AppState.panePreviews` is: a
///   cache filled by the foreground poll, showing each tab as it last looked,
///   the same bargain Mission Control makes.
///
/// - **The viewport text.** `ghostty_surface_read_text` on the visible region,
///   which is the terminal core's own state and therefore always current, and
///   is the fallback for a pane no frame was ever collected from — a tab
///   restored from a snapshot and never visited this run.
///
/// The image is composited over the pane's effective background because
/// `background-default-transparent` means unpainted cells arrive at alpha 0 —
/// sampled raw, a thumbnail would be glyphs floating on glass.
struct PanePreview {
    /// Downsampled copy of the pane's last rendered frame, already composited
    /// over `background`. nil when nothing has rendered.
    let image: NSImage?
    /// Trailing viewport lines, for the no-frame fallback.
    let lines: [String]
    /// The pane's effective background — the card's fill either way, so an
    /// image-less card still reads as that pane's terminal.
    let background: NSColor
    /// The frame's own width/height at capture time, so a card can be shaped
    /// to what was actually captured instead of cropping it to fit.
    let aspectRatio: CGFloat?
    /// The terminal's column count, so the text fallback can be typeset at the
    /// scale a real thumbnail of this pane would have been.
    ///
    /// For a pane that has never been on screen this is the width it has in
    /// `SurfaceIncubator`'s window (104 columns), not the width it would have
    /// in the real one — but it is the width this text was actually laid out
    /// at, which is what typesetting it needs.
    let columns: Int?

    var isEmpty: Bool { image == nil && lines.isEmpty }
}

enum PanePreviewCapture {
    /// Long edge of the stored thumbnail, in points. Cards render far smaller;
    /// the headroom keeps a 2x display sharp without holding a full frame.
    static let thumbnailLongEdge: CGFloat = 480

    /// Viewport rows kept for the text fallback. Generous, because the
    /// fallback is typeset small enough that a whole screen fits the card —
    /// the point is to look like the frame we couldn't capture.
    static let fallbackLineLimit = 80

    /// Snapshot `pane` for display in an overlay. Main-actor and synchronous:
    /// it locks the IOSurface read-only for the length of one copy, the same
    /// way the adaptive-background sampler does, and is called once per pane
    /// when a switcher gesture begins rather than per frame.
    @MainActor
    static func capture(_ pane: Pane) -> PanePreview {
        let background = pane.adaptiveBackgroundColor.map { NSColor(cgColor: $0) ?? MactermTheme.nsBg }
            ?? MactermTheme.nsBg
        guard let view = pane.nsView else {
            return PanePreview(image: nil, lines: [], background: background, aspectRatio: nil, columns: nil)
        }

        let image = (view.layer?.contents as? IOSurface).flatMap {
            thumbnail(from: $0, colorSpace: view.surfaceColorSpace, over: background)
        }
        // The text read is the fallback, so skip it whenever a frame exists —
        // it walks the whole viewport in the core.
        let lines = image == nil ? viewportLines(of: view) : []
        let aspect = image.map { $0.size.width / max($0.size.height, 1) }
        let columns = image == nil ? view.surfaceSize.map { Int($0.columns) } : nil
        return PanePreview(
            image: image,
            lines: lines,
            background: background,
            aspectRatio: aspect,
            columns: columns
        )
    }

    /// Width over height of the region `tab`'s panes occupy on screen, or nil
    /// while none of them is on screen.
    ///
    /// Taken as the union of the pane views' frames in window coordinates,
    /// which is the container the split tree fills — so a card given this
    /// aspect gives every leaf in the mosaic its pane's real proportions, and
    /// the frames drop in without being cropped. Every tab in a workspace
    /// fills the same container, so one measurement shapes the whole strip.
    @MainActor
    static func containerAspect(of tab: TerminalTab) -> CGFloat? {
        let frames = tab.splitRoot.allPanes()
            .compactMap(\.nsView)
            .filter { $0.window != nil }
            .map { $0.convert($0.bounds, to: nil) }
        guard let first = frames.first else { return nil }
        let union = frames.dropFirst().reduce(first) { $0.union($1) }
        guard union.width > 0, union.height > 0 else { return nil }
        return union.width / union.height
    }

    /// The viewport's rows, top down, with the trailing run of blank lines
    /// dropped.
    ///
    /// Top down and NOT trimmed on the left: these stand in for a picture of
    /// the screen, so row order and leading indentation are the shape of the
    /// thing. An earlier cut took the *last* lines and right-aligned nothing
    /// while the renderer bottom-aligned them, which put a fresh shell's
    /// prompt at the bottom of the card when the real pane draws it at the top.
    @MainActor
    private static func viewportLines(of view: GhosttyTerminalNSView) -> [String] {
        guard let text = view.readText(scrollback: false) else { return [] }
        var lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return Array(lines.prefix(fallbackLineLimit))
    }

    /// Downsample the surface's last frame over `background`.
    ///
    /// Validates the pixel format the way `AdaptiveTerminalBackgroundDetector`
    /// does and fails closed: this reads a private detail of ghostty's macOS
    /// renderer, so a layout change must degrade to the text fallback rather
    /// than misinterpret bytes.
    private static func thumbnail(
        from surface: IOSurface,
        colorSpace: NSColorSpace,
        over background: NSColor
    ) -> NSImage? {
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        guard width > 0, height > 0,
              IOSurfaceGetPixelFormat(surface) == kCVPixelFormatType_32BGRA,
              IOSurfaceGetBytesPerElement(surface) == 4,
              let cgColorSpace = colorSpace.cgColorSpace
        else {
            logger.debug("thumbnail: unexpected surface layout, falling back to text")
            return nil
        }

        var seed: UInt32 = 0
        guard IOSurfaceLock(surface, [.readOnly], &seed) == kIOReturnSuccess else { return nil }
        // `makeImage` copies, so the CGImage outlives the unlock.
        let frame: CGImage? = {
            defer { IOSurfaceUnlock(surface, [.readOnly], &seed) }
            guard let ctx = CGContext(
                data: IOSurfaceGetBaseAddress(surface),
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: IOSurfaceGetBytesPerRow(surface),
                space: cgColorSpace,
                // BGRA, premultiplied — what the renderer writes.
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGImageByteOrderInfo.order32Little.rawValue
            )
            else { return nil }
            return ctx.makeImage()
        }()
        guard let frame else { return nil }

        return composite(frame, over: background, colorSpace: cgColorSpace)
    }

    /// Scale `frame` down to `thumbnailLongEdge` and paint it over the pane's
    /// background so transparent (unpainted) cells read as the terminal's own
    /// color instead of the glass behind the card.
    private static func composite(
        _ frame: CGImage,
        over background: NSColor,
        colorSpace: CGColorSpace
    ) -> NSImage? {
        let scale = min(1, thumbnailLongEdge / CGFloat(max(frame.width, frame.height)))
        let size = CGSize(
            width: max(1, (CGFloat(frame.width) * scale).rounded()),
            height: max(1, (CGFloat(frame.height) * scale).rounded())
        )
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGImageByteOrderInfo.order32Little.rawValue
        )
        else { return nil }

        let rect = CGRect(origin: .zero, size: size)
        ctx.setFillColor((background.usingColorSpace(.sRGB) ?? background).cgColor)
        ctx.fill(rect)
        ctx.interpolationQuality = .high
        ctx.draw(frame, in: rect)
        guard let out = ctx.makeImage() else { return nil }
        // Point size == pixel size: the card scales it down further, and NSImage
        // needs a size for layout regardless of the display's backing scale.
        return NSImage(cgImage: out, size: size)
    }
}
