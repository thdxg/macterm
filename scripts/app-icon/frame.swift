// Draws the two frame rings, the glass pane, the cross, the cross's shade and
// the screen's gradient of the app icon: Macterm/AppIcon.icon/Assets/
// frame-silver.png, frame-dark.png, glass-pane.png, cross.png, cross-shade.png
// and screen-gradient.png.
//
// The rings follow the macOS icon shape: a rounded square with continuous
// corners, as SwiftUI's `RoundedRectangle(style: .continuous)` draws them,
// whose radius is `iconRadius` of the side. That value is measured from the
// system's own render of the icon (the diagonal gap from the body's corner
// to its edge). Every edge of a ring is that shape, inset: its corner radius
// is the icon's radius minus the inset, so the edges are concentric with
// the icon and with each other.
//
// Each image covers the whole 1024 pt canvas at 2 pixels a point. In a
// group of scale 0.58, a layer scale of 0.5 / 0.58 places it. The glass pane
// covers `paneSpan` instead, centered, so its layer scale is that much larger.
//
// Usage: swift scripts/app-icon/frame.swift <AppIcon.icon/Assets>

import AppKit
import CoreImage
import SwiftUI

/// The macOS icon shape's corner radius, as a share of the side.
let iconRadius = 0.2615
let canvas = 1024.0
let pixelsPerPoint = 2.0

/// Each shape: its outer edge and, for a ring, its inner edge, as insets
/// from the canvas edge in points. A negative outer inset runs past the icon
/// shape, which clips it. The ring widths are Ghostty's icon's, measured on
/// its system render: on its 824 px body the silver bezel is 42 px and the
/// dark ring ends at 87 px, which on the 1024 pt canvas is 52 pt and 108 pt.
/// The dark ring starts 4 pt under the silver, so that no gap shows between
/// them.
let rings: [(name: String, outer: Double, inner: Double)] = [
    ("frame-silver", -8, 52),
    ("frame-dark", 48, 108),
]

/// The screen: the dark ring's opening, and 4 pt under the ring, so that no
/// gap shows. The cross fills its part of it.
let screenInset = 104.0

/// The glass pane runs past the icon on every side, so that its only edges in
/// the icon are the ones along the cross: glass bends light at its edges, and
/// an edge at the frame would bend the characters there too.
let paneSpan = 1.5 * canvas

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: frame.swift <AppIcon.icon/Assets>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

/// The icon shape, inset by `inset` points: concentric with the icon.
func shape(inset: Double) -> CGPath {
    let rect = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
    let radius = max(0, canvas * iconRadius - inset)
    return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

/// The cross is the gap between four quadrants of the screen, drawn as one
/// shape, as the v1.32.1 icon's glyph left it between its four panes. Each
/// quadrant rounds only its corner that faces the middle, so the cross opens
/// up where its arms meet. The position is that glyph's, moved onto the
/// screen: the arms cross 60% of the way across and down. The gap is as wide
/// as the silver frame (52 pt). Each inner corner has the radius of the dark ring's inner
/// corners (about 160 pt), so every quadrant's corners match. The arms run
/// 4 pt under the dark ring. Points run down from the top-left.
let cross = (x: 597.0, y: 593.0, gap: rings[0].inner, radius: canvas * iconRadius - rings[1].inner)
/// The cross turns clockwise by this many degrees about its middle, with
/// the panes, and `characters.swift` turns the characters' grids with it.
let crossAngle = 8.0

/// The four quadrants, turned by `crossAngle`. Each one runs far past the
/// screen on its outer sides. The glass pane is the four of them, so it never
/// covers the cross.
func quadrantPaths() -> [CGPath] {
    let far = 2 * canvas
    let half = cross.gap / 2
    let quadrants: [(CGRect, RectangleCornerRadii)] = [
        (CGRect(x: -far, y: -far, width: cross.x - half + far, height: cross.y - half + far),
         RectangleCornerRadii(bottomTrailing: cross.radius)),
        (CGRect(x: cross.x + half, y: -far, width: far, height: cross.y - half + far),
         RectangleCornerRadii(bottomLeading: cross.radius)),
        (CGRect(x: -far, y: cross.y + half, width: cross.x - half + far, height: far),
         RectangleCornerRadii(topTrailing: cross.radius)),
        (CGRect(x: cross.x + half, y: cross.y + half, width: far, height: far),
         RectangleCornerRadii(topLeading: cross.radius)),
    ]
    // Points run down, so a positive angle turns clockwise.
    var turn = CGAffineTransform(translationX: cross.x, y: cross.y)
        .rotated(by: crossAngle * .pi / 180)
        .translatedBy(x: -cross.x, y: -cross.y)
    return quadrants.map { UnevenRoundedRectangle(cornerRadii: $1, style: .continuous).path(in: $0).cgPath.copy(using: &turn)! }
}

/// Draws `paths`, with the cross's points running down from the top-left.
func drawDown(_ context: CGContext, _ paths: [CGPath], rule: CGPathFillRule) {
    // CoreGraphics runs up from the bottom-left.
    context.translateBy(x: 0, y: canvas)
    context.scaleBy(x: 1, y: -1)
    for path in paths { context.addPath(path) }
    context.fillPath(using: rule)
}

/// The cross's shade on the characters: the cross, blurred and moved down,
/// as if the cross casts it from a light above. It is a flat layer in the
/// characters' group, whose images are 1 pixel a point, and the paint rule
/// fills it black.
let shade = (offset: 20.0, blur: 24.0)

/// Draws a mask at `pixels` square that covers `span` points, centered on the canvas.
func mask(span: Double = canvas, pixels: Int, draw: (CGContext) -> Void) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.scaleBy(x: Double(pixels) / span, y: Double(pixels) / span)
    context.translateBy(x: (span - canvas) / 2, y: (span - canvas) / 2)
    // Icon Composer replaces the color with the layer's fill.
    context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    draw(context)
    return context.makeImage()!
}

func writeImage(_ image: CGImage, _ name: String) {
    let url = outDir.appendingPathComponent("\(name).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
}

/// Writes a mask that covers `span` points, centered on the canvas, at 2 pixels a point.
func write(_ name: String, span: Double = canvas, draw: (CGContext) -> Void) {
    writeImage(mask(span: span, pixels: Int(canvas * pixelsPerPoint), draw: draw), name)
}

for ring in rings {
    write(ring.name) { context in
        context.addPath(shape(inset: ring.outer))
        context.addPath(shape(inset: ring.inner))
        context.fillPath(using: .evenOdd)
    }
}
write("glass-pane", span: paneSpan) { drawDown($0, quadrantPaths(), rule: .winding) }
/// The screen less the quadrants.
func drawCross(_ context: CGContext) {
    context.addPath(shape(inset: screenInset))
    context.clip()
    let everything = CGPath(rect: CGRect(x: -canvas, y: -canvas, width: 3 * canvas, height: 3 * canvas), transform: nil)
    drawDown(context, [everything] + quadrantPaths(), rule: .evenOdd)
}
write("cross", draw: drawCross)

// CoreImage runs y up, so down is a negative move.
let crossImage = CIImage(cgImage: mask(pixels: Int(canvas), draw: drawCross))
let shaded = crossImage.clampedToExtent()
    .applyingGaussianBlur(sigma: shade.blur)
    .transformed(by: CGAffineTransform(translationX: 0, y: -shade.offset))
    .cropped(to: crossImage.extent)
writeImage(CIContext().createCGImage(shaded, from: crossImage.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))!, "cross-shade")

/// The screen's gradient: opaque at the top of the screen and transparent at
/// its bottom, along the cross's turn. The icon's background is the theme's
/// background, and the paint rule fills this layer with the theme's lid, so
/// the screen fades from the lid at the top to the background at the bottom. It is a flat layer at the bottom
/// of the characters' group, whose images are 1 pixel a point.
let screenGradient: CGImage = {
    let pixels = Int(canvas)
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let gradient = CGGradient(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colorComponents: [1, 1, 1, 1, 1, 1, 1, 0], locations: [0, 1], count: 2
    )!
    // Down the screen, turned clockwise by `crossAngle`: points run down from
    // the top-left, and CoreGraphics runs up.
    let angle = crossAngle * .pi / 180
    let half = (canvas - 2 * screenInset) / 2
    let down = (x: -sin(angle) * half, y: cos(angle) * half)
    let middle = canvas / 2
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: middle - down.x, y: canvas - (middle - down.y)),
        end: CGPoint(x: middle + down.x, y: canvas - (middle + down.y)),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    return context.makeImage()!
}()
writeImage(screenGradient, "screen-gradient")
