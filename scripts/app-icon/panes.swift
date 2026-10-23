// Draws the three pane masks of the app icon:
// Macterm/AppIcon.icon/Assets/{front,middle,back}-pane.png.
//
// Each pane is a curved glass card, turned in perspective: a short far edge on
// the left and a tall near edge on the right. The top and bottom edges run from
// corner to corner along an arc that rises fast and flattens, as the edge of a
// card bent toward the viewer does. Icon Composer fills each mask with one
// color and draws it as glass, so the outline is all that makes the curve.
//
// Each image has the same space above and below the pane, so the pane's
// center, and so its place in icon.json, does not depend on the curve.
//
// Usage: swift scripts/app-icon/panes.swift <AppIcon.icon/Assets>

import CoreGraphics
import Foundation
import ImageIO

struct Pane {
    var name: String
    var width: Double
    var height: Double
    /// Where the top edge meets the far (left) and near (right) side, y down.
    /// The bottom edge mirrors it. A negative value is above the image: the
    /// near corner's rounding brings the outline back inside.
    var farTop: Double
    var nearTop: Double
    var farCorner: Double
    var nearCorner: Double
}

let panes = [
    Pane(name: "front", width: 232, height: 749, farTop: 148, nearTop: -47, farCorner: 70, nearCorner: 60),
    Pane(name: "middle", width: 414, height: 728, farTop: 121, nearTop: -20, farCorner: 80, nearCorner: 60),
    Pane(name: "back", width: 562, height: 666, farTop: 71, nearTop: -12, farCorner: 90, nearCorner: 65),
]

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: panes.swift <AppIcon.icon/Assets>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

for pane in panes {
    let samples = 400
    let slant = pane.farTop - pane.nearTop
    // The top and bottom edges, y down.
    let columns = (0 ... samples).map { step -> (x: Double, top: Double, bottom: Double) in
        let t = Double(step) / Double(samples)
        let top = pane.farTop - slant * sin(.pi / 2 * t)
        return (t * pane.width, top, pane.height - top)
    }
    let pad = (max(0, -pane.nearTop) + 4).rounded()
    let height = pane.height + 2 * pad
    let topEdge = columns.map { CGPoint(x: $0.x, y: $0.top + pad) }
    let bottomEdge = columns.map { CGPoint(x: $0.x, y: $0.bottom + pad) }

    /// The index on `edge` that is `distance` points along it from its start.
    func index(along edge: [CGPoint], _ distance: Double) -> Int {
        var run = 0.0
        for index in 1 ..< edge.count {
            run += hypot(edge[index].x - edge[index - 1].x, edge[index].y - edge[index - 1].y)
            if run >= distance { return index }
        }
        return edge.count - 1
    }

    // Top edge left to right, near side down, bottom edge right to left, far
    // side up. Each corner is a quadratic curve that starts its radius away
    // from the corner along both edges.
    let first = index(along: topEdge, pane.farCorner)
    let last = topEdge.count - 1 - index(along: topEdge.reversed(), pane.nearCorner)
    let path = CGMutablePath()
    path.move(to: topEdge[first])
    for point in topEdge[first ... last] {
        path.addLine(to: point)
    }
    let nearTop = topEdge[topEdge.count - 1]
    let nearBottom = bottomEdge[bottomEdge.count - 1]
    path.addQuadCurve(to: CGPoint(x: pane.width, y: nearTop.y + pane.nearCorner), control: nearTop)
    path.addLine(to: CGPoint(x: pane.width, y: nearBottom.y - pane.nearCorner))
    path.addQuadCurve(to: bottomEdge[last], control: nearBottom)
    for point in bottomEdge[first ... last].reversed() {
        path.addLine(to: point)
    }
    let farBottom = bottomEdge[0]
    let farTop = topEdge[0]
    path.addQuadCurve(to: CGPoint(x: 0, y: farBottom.y - pane.farCorner), control: farBottom)
    path.addLine(to: CGPoint(x: 0, y: farTop.y + pane.farCorner))
    path.addQuadCurve(to: topEdge[first], control: farTop)
    path.closeSubpath()

    let context = CGContext(
        data: nil, width: Int(pane.width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // y down, as the outline is.
    context.translateBy(x: 0, y: height)
    context.scaleBy(x: 1, y: -1)
    context.addPath(path)
    // Icon Composer replaces the color with the layer's fill.
    context.setFillColor(CGColor(srgbRed: 0.21, green: 0.22, blue: 0.27, alpha: 1))
    context.fillPath()
    let url = outDir.appendingPathComponent("\(pane.name)-pane.png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
}
