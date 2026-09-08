import AppKit
import CoreGraphics
import IOSurface
import os

private let logger = Logger(subsystem: appBundleID, category: "PanePreview")

/// A visual snapshot of one pane's contents, cheap enough to render in a
/// transient overlay (the tab switcher) and re-sampled a few times a second
/// while that overlay is up.
///
/// The picture is the rendered frame: ghostty's surface layer is an
/// `IOSurfaceLayer` whose `contents` is the last frame it drew (the same
/// handle `AdaptiveTerminalChrome` samples for the adaptive background), so a
/// thumbnail needs no renderer of our own — just a downsampled copy.
///
/// **Only a pane whose renderer is awake has one.** Measured: an inactive
/// tab's panes keep their NSView (it is pane-owned, warmed by
/// `SurfaceIncubator`) but their `layer.contents` is nil — ghostty does not
/// leave a frame parked in an occluded surface. So the switcher sets
/// `GhosttyTerminalNSView.rendersForPreview` on every pane it offers, which
/// reports the surface visible so libghostty draws it again, and samples them
/// all on a timer until the gesture commits (`AppState.beginLivePreviews`).
/// A card therefore shows its tab as it is now; the only moment it has no
/// frame is the tick or two between the wake-up and the renderer's first
/// draw, which the overlay's fade-in covers. (An earlier design sampled the
/// visible tab from the foreground poll and typeset a viewport-text fallback
/// for tabs never seen; both existed only because off-screen panes could not
/// be sampled, and went when they could.)
///
/// The image is composited over the pane's effective background because
/// `background-default-transparent` means unpainted cells arrive at alpha 0 —
/// sampled raw, a thumbnail would be glyphs floating on glass.
struct PanePreview {
    /// Downsampled copy of the pane's last rendered frame, already composited
    /// over `background`. nil when nothing has rendered yet.
    let image: NSImage?
    /// The pane's effective background — the card's fill either way, so an
    /// image-less card still reads as that pane's terminal.
    let background: NSColor
    /// The frame's own width/height at capture time, so a card can be shaped
    /// to what was actually captured instead of cropping it to fit.
    let aspectRatio: CGFloat?
    /// Identity of the IOSurface `image` was sampled from. The renderer
    /// presents from a swap chain of three, so a new frame always lands in a
    /// different surface than the last — which makes "same surface as before"
    /// a reliable "nothing new was drawn" and lets the live sampling skip the
    /// copy for a pane that is sitting still. nil when there is no frame.
    let frameID: IOSurfaceID?

    init(image: NSImage?, background: NSColor, aspectRatio: CGFloat?, frameID: IOSurfaceID? = nil) {
        self.image = image
        self.background = background
        self.aspectRatio = aspectRatio
        self.frameID = frameID
    }
}

enum PanePreviewCapture {
    /// Long edge of the stored thumbnail, in points. Cards render far smaller;
    /// the headroom keeps a 2x display sharp without holding a full frame.
    static let thumbnailLongEdge: CGFloat = 480

    /// Snapshot `pane` for display in an overlay. Main-actor and synchronous:
    /// it locks the IOSurface read-only for the length of one copy, the same
    /// way the adaptive-background sampler does, and is called per pane a few
    /// times a second while a switcher gesture is held rather than per frame.
    ///
    /// `previous` is the preview last stored for this pane: when the surface
    /// on the layer is the very one it was sampled from, nothing has been
    /// drawn since and it is returned as is — the live sampling's whole cost
    /// is the copy, and a pane at rest should cost it nothing.
    @MainActor
    static func capture(_ pane: Pane, reusing previous: PanePreview? = nil) -> PanePreview {
        let background = pane.adaptiveBackgroundColor.map { NSColor(cgColor: $0) ?? MactermTheme.nsBg }
            ?? MactermTheme.nsBg
        guard let view = pane.nsView else {
            return PanePreview(image: nil, background: background, aspectRatio: nil)
        }

        let surface = view.layer?.contents as? IOSurface
        if let surface, let previous, previous.image != nil,
           previous.frameID == IOSurfaceGetID(surface), previous.background == background
        {
            return previous
        }
        let image = surface.flatMap {
            thumbnail(from: $0, colorSpace: view.surfaceColorSpace, over: background)
        }
        let aspect = image.map { $0.size.width / max($0.size.height, 1) }
        return PanePreview(
            image: image,
            background: background,
            aspectRatio: aspect,
            frameID: image == nil ? nil : surface.map { IOSurfaceGetID($0) }
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
        defer { IOSurfaceUnlock(surface, [.readOnly], &seed) }
        // The frame is wrapped, not copied: the provider reads the locked
        // surface memory directly and the only pixels written are the
        // thumbnail's own. `composite` draws synchronously into its own
        // context, so nothing reads through the provider after the unlock.
        // An earlier cut went through `CGContext.makeImage`, a full-frame copy
        // that at several megabytes per pane, several times a second, was
        // most of what the live sampling cost.
        let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: IOSurfaceGetBaseAddress(surface),
            size: bytesPerRow * height,
            releaseData: { _, _, _ in }
        ),
            let frame = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: cgColorSpace,
                // BGRA, premultiplied — what the renderer writes.
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGImageByteOrderInfo.order32Little.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else { return nil }

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
        // Medium, not high: the card shows this at a fraction of its size
        // again, and high-quality resampling of a full retina frame was the
        // other half of the live sampling's cost.
        ctx.interpolationQuality = .medium
        ctx.draw(frame, in: rect)
        guard let out = ctx.makeImage() else { return nil }
        // Point size == pixel size: the card scales it down further, and NSImage
        // needs a size for layout regardless of the display's backing scale.
        return NSImage(cgImage: out, size: size)
    }
}
