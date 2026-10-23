// Draws Macterm's document icon: the page that Finder shows for a file that
// opens with Macterm by default (`CFBundleTypeIconFile` in Info.plist).
//
// The page is the app icon's background with the app icon's pane glyph at its
// top-left. The page's bottom color and the glyph's geometry come from
// `Macterm/AppIcon.icon`. The page outline follows the system's generic
// document (`NSWorkspace.icon(for:)` at 1024 px, measured on macOS 27).
//
// The glyph is real Liquid Glass. `macterm-icon-renderer` (the adaptive
// icon's helper) draws the whole app icon on a background gradient that
// matches the page at the glyph's rows, and this script crops the glyph out
// with soft edges. Glass shows what is behind it, so a glyph that is cut out
// with a transparency would show a different background on the page. A crop
// of a render on the page's own colors needs no transparency: its background
// is the page.
//
// The script compiles its own copy of the icon, with the character group
// hidden: the page is plain, so the glass shows the page's colors and its
// grain.
//
// Usage: swift scripts/document-icon/render.swift <AppIcon.icon> <macterm-icon-renderer> <out.iconset>

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: render.swift <AppIcon.icon> <macterm-icon-renderer> <out.iconset>\n".utf8))
    exit(2)
}
let iconURL = URL(fileURLWithPath: arguments[1])
let helperURL = URL(fileURLWithPath: arguments[2])
let outURL = URL(fileURLWithPath: arguments[3])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("render.swift: \(message)\n".utf8))
    exit(1)
}

// MARK: - The app icon's source

struct IconFile: Decodable {
    struct Fill: Decodable {
        var solid: String?
    }

    struct Position: Decodable {
        var scale: Double
        var translationInPoints: [Double]
        enum CodingKeys: String, CodingKey {
            case scale
            case translationInPoints = "translation-in-points"
        }
    }

    struct Layer: Decodable {
        var fill: Fill
        var imageName: String
        var name: String
        var position: Position
        enum CodingKeys: String, CodingKey {
            case fill
            case imageName = "image-name"
            case name
            case position
        }
    }

    struct Group: Decodable {
        var layers: [Layer]
        var name: String
        var position: Position
    }

    var fill: Fill
    var groups: [Group]
}

let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// `srgb:r,g,b,a` or `display-p3:r,g,b,a`, as Icon Composer writes it.
func color(_ text: String) -> CGColor {
    let parts = text.split(separator: ":", maxSplits: 1)
    let space = parts[0] == "display-p3" ? p3 : sRGB
    let components = parts[1].split(separator: ",").map { CGFloat(Double($0)!) }
    return CGColor(colorSpace: space, components: components)!
}

let icon = try JSONDecoder().decode(IconFile.self, from: Data(contentsOf: iconURL.appendingPathComponent("icon.json")))
/// The app icon's background: one flat color.
guard let solidFill = icon.fill.solid else { fail("expected a solid background in icon.json") }
let background = color(solidFill)

/// The icon canvas is 1024 pt, and one image pixel is one point.
let iconCanvas = 1024.0

/// The rect of the opaque pixels of a mask, y down, in its pixels.
func opaqueBounds(of image: CGImage) -> CGRect {
    let width = image.width
    let height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var minX = width, minY = height, maxX = -1, maxY = -1
    for y in 0 ..< height {
        for x in 0 ..< width where bytes[(y * width + x) * 4 + 3] > 127 {
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
    }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

/// Each pane's rect on the app icon's canvas, y down: its opaque pixels, not
/// its image, whose padding keeps the pane's center. The frame is the app
/// icon's chiclet rim, which the page replaces.
let paneRects: [CGRect] = icon.groups.compactMap { group in
    guard let layer = group.layers.first, layer.name.hasSuffix("-pane") else { return nil }
    let url = iconURL.appendingPathComponent("Assets").appendingPathComponent(layer.imageName)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let mask = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("cannot read \(url.path)") }
    let scale = layer.position.scale * group.position.scale
    let center = CGPoint(
        x: iconCanvas / 2 + layer.position.translationInPoints[0] * group.position.scale,
        y: iconCanvas / 2 + layer.position.translationInPoints[1] * group.position.scale
    )
    let opaque = opaqueBounds(of: mask)
    return CGRect(
        x: center.x + (opaque.minX - Double(mask.width) / 2) * scale,
        y: center.y + (opaque.minY - Double(mask.height) / 2) * scale,
        width: opaque.width * scale,
        height: opaque.height * scale
    )
}
guard paneRects.count == 3 else { fail("expected 3 panes in \(iconURL.path), found \(paneRects.count)") }
let glyphBounds = paneRects.dropFirst().reduce(paneRects[0]) { $0.union($1) }

// MARK: - The page, on a 1024 canvas, y down

let page = CGRect(x: 168, y: 58, width: 688, height: 908)
let cornerRadius = 34.0
/// The fold starts on the top edge at `foldX` and ends on the right edge at
/// `foldY`: a 45° cut, as on the system's page.
let foldX = 590.0
let foldY = page.minY + (page.maxX - foldX)
let foldRadius = 40.0

/// The glyph's box on the page: its top-left corner and its height.
let glyphOrigin = CGPoint(x: page.minX + 88, y: page.minY + 92)
let glyphHeight = 300.0
let glyphScale = glyphHeight / glyphBounds.height

/// A point of the app icon's canvas, on the page.
func onPage(_ point: CGPoint) -> CGPoint {
    CGPoint(
        x: glyphOrigin.x + (point.x - glyphBounds.minX) * glyphScale,
        y: glyphOrigin.y + (point.y - glyphBounds.minY) * glyphScale
    )
}

/// The page's top color. The app icon is flat, and its characters draw its
/// gradient. The page has no characters, so it has a gradient of its own, from
/// this color down to the icon's background.
let pageTop = CGColor(colorSpace: p3, components: [0.155, 0.159, 0.206, 1])!
/// The page's gradient, top to bottom.
let pageGradient = [pageTop, background]

/// The page's color at a row of the page.
func pageColor(atY y: Double) -> CGColor {
    blend(pageGradient[0], toward: pageGradient[1], by: (y - page.minY) / page.height)
}

/// `color` moved `amount` of the way to `target`, in Display P3. An amount
/// outside 0…1 extrapolates.
func blend(_ color: CGColor, toward target: CGColor, by amount: Double) -> CGColor {
    let from = color.converted(to: p3, intent: .defaultIntent, options: nil)!.components!
    let to = target.converted(to: p3, intent: .defaultIntent, options: nil)!.components!
    let mixed: [CGFloat] = (0 ..< 3).map { from[$0] + (to[$0] - from[$0]) * amount } + [1]
    return CGColor(colorSpace: p3, components: mixed)!
}

// MARK: - The glass glyph

/// The render's edge, in pixels. The glyph comes out about 700 px high, more
/// than the 300 px of the largest document icon.
let renderPixels = 2048
/// The part of the app icon's canvas that the page takes: the glyph and its
/// shadow, and none of the frame.
let glyphCrop = CGRect(
    x: glyphBounds.minX - 40, y: glyphBounds.minY - 30,
    width: glyphBounds.width + 100, height: glyphBounds.height + 80
)
/// How far in from the crop's edge the glyph fades in, on the app icon's canvas.
let feather = 28.0
/// The matte values between the glyph's shadow and its glass.
let glassMatte = 0.12 ... 0.3

func requestColor(_ color: CGColor) -> [String: Double] {
    let components = color.converted(to: sRGB, intent: .defaultIntent, options: nil)!.components!
    return ["red": components[0], "green": components[1], "blue": components[2]]
}

/// The group of the app icon that the page leaves out: the characters.
let pageHidesGroup = "Characters"

/// Compiles a copy of the icon with its character group hidden, as Xcode compiles
/// the app's own, and returns the path of the catalog.
func compileCatalog() -> String {
    let work = FileManager.default.temporaryDirectory.appendingPathComponent("document-icon-\(getpid())")
    try? FileManager.default.removeItem(at: work)
    let copy = work.appendingPathComponent("AppIcon.icon")
    do {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: iconURL, to: copy)
        let jsonURL = copy.appendingPathComponent("icon.json")
        guard var document = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any],
              var groups = document["groups"] as? [[String: Any]]
        else { fail("cannot read icon.json") }
        for group in groups.indices where groups[group]["name"] as? String == pageHidesGroup {
            groups[group]["hidden"] = true
        }
        document["groups"] = groups
        try JSONSerialization.data(withJSONObject: document).write(to: jsonURL)
    } catch {
        fail("cannot copy the icon: \(error)")
    }
    let actool = Process()
    actool.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    actool.arguments = [
        "actool", copy.path, "--compile", work.path, "--platform", "macosx",
        "--minimum-deployment-target", "14.0", "--app-icon", "AppIcon",
        "--output-partial-info-plist", work.appendingPathComponent("partial.plist").path,
    ]
    actool.standardOutput = FileHandle.nullDevice
    do { try actool.run() } catch { fail("cannot run actool: \(error)") }
    actool.waitUntilExit()
    let catalog = work.appendingPathComponent("Assets.car")
    guard actool.terminationStatus == 0, FileManager.default.fileExists(atPath: catalog.path) else {
        fail("actool could not compile the icon")
    }
    return catalog.path
}

let catalogPath = compileCatalog()

/// The app icon in real glass, from the helper, on a background gradient
/// from `top` to `bottom`.
func renderGlassIcon(top: CGColor, bottom: CGColor) -> CGImage {
    let request: [String: Any] = [
        "catalogPath": catalogPath,
        "iconName": "AppIcon",
        "appearance": "dark",
        "backgroundTop": requestColor(top),
        "backgroundBottom": requestColor(bottom),
        // Bottom to top, as `AdaptiveIconRequest.layers`: the reverse of `groups`.
        // The hidden group drops out of the compiled icon, so its color does too.
        "layers": icon.groups.reversed().filter { $0.name != pageHidesGroup }.map {
            requestColor(color($0.layers[0].fill.solid!))
        },
        "pixels": renderPixels,
    ]
    let process = Process()
    process.executableURL = helperURL
    process.arguments = [String(decoding: try! JSONSerialization.data(withJSONObject: request), as: UTF8.self)]
    let output = Pipe()
    process.standardOutput = output
    do { try process.run() } catch { fail("cannot run \(helperURL.path): \(error)") }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("macterm-icon-renderer exited \(process.terminationStatus)") }
    return image
}

/// The RGBA bytes of an image, in Display P3.
func pixels(of image: CGImage) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(
        data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
        space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return bytes
}

/// A white image whose alpha is `alpha`, one value for each pixel.
func alphaImage(_ alpha: [UInt8], width: Int, height: Int) -> CGImage {
    let bytes = alpha.flatMap { [$0, $0, $0, $0] } // Premultiplied: white is its alpha.
    return CGImage(
        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
        space: p3, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: true,
        intent: .defaultIntent
    )!
}

/// The smooth step from 0 at `low` to 1 at `high`.
func smoothStep(_ low: Double, _ high: Double, _ value: Double) -> Double {
    let t = min(1, max(0, (value - low) / (high - low)))
    return t * t * (3 - 2 * t)
}

/// The glass glyph on the page.
struct Glyph {
    /// The crop of the render on the page's colors, faded in from its edges.
    var image: CGImage
    /// Where the glyph's glass is: the area that the grain keeps off.
    var coverage: CGImage
    /// The crop's rect on the page.
    var rect: CGRect
}

func glassGlyph() -> Glyph {
    // The chiclet's gradient runs over the whole canvas, so its ends are the
    // page colors at the rows where the canvas's top and bottom would land.
    let render = renderGlassIcon(
        top: pageColor(atY: onPage(.zero).y),
        bottom: pageColor(atY: onPage(CGPoint(x: 0, y: iconCanvas)).y)
    )
    let black = CGColor(colorSpace: sRGB, components: [0, 0, 0, 1])!
    let white = CGColor(colorSpace: sRGB, components: [1, 1, 1, 1])!
    let onBlack = renderGlassIcon(top: black, bottom: black)
    let onWhite = renderGlassIcon(top: white, bottom: white)

    // Where the helper puts the body: `IconCanvas` in IconRenderer/main.swift.
    let canvas = Double(renderPixels)
    let body = (canvas * 824 / 1024).rounded()
    let inset = ((canvas - body) / 2).rounded()
    let unit = body / iconCanvas
    let pixelCrop = CGRect(
        x: inset + glyphCrop.minX * unit,
        y: inset + glyphCrop.minY * unit,
        width: glyphCrop.width * unit,
        height: glyphCrop.height * unit
    ).integral
    guard let crop = render.cropping(to: pixelCrop),
          let blackCrop = onBlack.cropping(to: pixelCrop),
          let whiteCrop = onWhite.cropping(to: pixelCrop)
    else { fail("cannot crop the render") }
    let width = crop.width
    let height = crop.height

    // Fade the crop in from its edges, so that it meets the page with no seam.
    let fade = feather * unit
    var alpha = [UInt8](repeating: 0, count: width * height)
    for y in 0 ..< height {
        for x in 0 ..< width {
            let edge = min(Double(x), Double(y), Double(width - 1 - x), Double(height - 1 - y))
            alpha[y * width + x] = UInt8((smoothStep(0, fade, edge) * 255).rounded())
        }
    }
    let mask = CGImage(
        maskWidth: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
        provider: CGDataProvider(data: Data(alpha.map { 255 - $0 }) as CFData)!, decode: nil, shouldInterpolate: true
    )!
    guard let faded = crop.masking(mask) else { fail("cannot fade the crop") }

    // Where the glass is. What differs between the render on black and the
    // render on white is the background that shows through, so the matte is
    // 1 - (white - black). It is near 0 in the panes' shadow and higher on the
    // panes. The panes are partly clear, so the step starts low: at 0.3 and
    // 0.6 the grain covered the lower half of the back pane.
    let blackPixels = pixels(of: blackCrop)
    let whitePixels = pixels(of: whiteCrop)
    let coverage: [UInt8] = (0 ..< width * height).map { pixel in
        let difference = (0 ..< 3).reduce(0) { $0 + Int(whitePixels[pixel * 4 + $1]) - Int(blackPixels[pixel * 4 + $1]) }
        let matte = 1 - Double(difference) / (3 * 255)
        return UInt8((smoothStep(glassMatte.lowerBound, glassMatte.upperBound, matte) * 255).rounded())
    }

    let topLeft = onPage(glyphCrop.origin)
    let bottomRight = onPage(CGPoint(x: glyphCrop.maxX, y: glyphCrop.maxY))
    return Glyph(
        image: faded,
        coverage: alphaImage(coverage, width: width, height: height),
        rect: CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    )
}

let glyph = glassGlyph()

// MARK: - Grain

/// The strongest speck of grain: the alpha of a white or black pixel over the page.
let grainStrength = 0.06
/// Below this edge, in pixels, the icon has no grain: one speck would be a
/// large part of the glyph.
let grainMinimumPixels = 64

/// SplitMix64, so that each run draws the same grain and a new run changes
/// `Document.icns` only when the drawing changes.
struct Grain: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Specks of white and black, one for each pixel: the sum of two uniform
/// values, so that most specks are faint and few are strong.
func grain(pixels: Int) -> CGImage? {
    guard pixels >= grainMinimumPixels else { return nil }
    var random = Grain(state: UInt64(pixels))
    var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
    for pixel in 0 ..< pixels * pixels {
        let value = (Double.random(in: -1 ... 1, using: &random) + Double.random(in: -1 ... 1, using: &random)) / 2
        let alpha = UInt8((abs(value) * grainStrength * 255).rounded())
        let level = value > 0 ? alpha : 0 // Premultiplied: white is its alpha.
        bytes[pixel * 4] = level
        bytes[pixel * 4 + 1] = level
        bytes[pixel * 4 + 2] = level
        bytes[pixel * 4 + 3] = alpha
    }
    return CGImage(
        width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4,
        space: p3, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent
    )
}

// MARK: - Drawing

func pagePath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: page.minX, y: page.midY))
    path.addArc(tangent1End: CGPoint(x: page.minX, y: page.minY), tangent2End: CGPoint(x: foldX, y: page.minY), radius: cornerRadius)
    path.addArc(tangent1End: CGPoint(x: foldX, y: page.minY), tangent2End: CGPoint(x: page.maxX, y: foldY), radius: 14)
    path.addArc(tangent1End: CGPoint(x: page.maxX, y: foldY), tangent2End: CGPoint(x: page.maxX, y: page.maxY), radius: 14)
    path.addArc(tangent1End: CGPoint(x: page.maxX, y: page.maxY), tangent2End: CGPoint(x: page.minX, y: page.maxY), radius: cornerRadius)
    path.addArc(tangent1End: CGPoint(x: page.minX, y: page.maxY), tangent2End: CGPoint(x: page.minX, y: page.minY), radius: cornerRadius)
    path.closeSubpath()
    return path
}

/// The folded-over corner: the triangle that the cut removed, flipped onto the page.
func flapPath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: foldX + 30, y: page.minY + 30))
    path.addArc(tangent1End: CGPoint(x: foldX, y: page.minY), tangent2End: CGPoint(x: foldX, y: foldY), radius: 14)
    path.addArc(tangent1End: CGPoint(x: foldX, y: foldY), tangent2End: CGPoint(x: page.maxX, y: foldY), radius: foldRadius)
    path.addArc(tangent1End: CGPoint(x: page.maxX, y: foldY), tangent2End: CGPoint(x: foldX, y: page.minY), radius: 14)
    path.closeSubpath()
    return path
}

func render(pixels: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let unit = Double(pixels) / iconCanvas
    // y down, in canvas points. Shadow offsets and blurs stay in device
    // pixels, and a device y offset that is negative moves a shadow down.
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: unit, y: -unit)
    context.interpolationQuality = .high

    // The page and its drop shadow.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -8 * unit), blur: 24 * unit, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(pagePath())
    context.setFillColor(pageGradient[1])
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(pagePath())
    context.clip()
    context.drawLinearGradient(
        CGGradient(colorsSpace: p3, colors: pageGradient as CFArray, locations: [0, 1])!,
        start: CGPoint(x: 0, y: page.minY), end: CGPoint(x: 0, y: page.maxY), options: []
    )

    // The glass glyph. The image is y down; draw it flipped back.
    context.saveGState()
    context.translateBy(x: 0, y: glyph.rect.maxY + glyph.rect.minY)
    context.scaleBy(x: 1, y: -1)
    context.draw(glyph.image, in: glyph.rect)
    context.restoreGState()

    // The fold casts its shadow onto the page.
    context.saveGState()
    context.setShadow(offset: CGSize(width: -4 * unit, height: -8 * unit), blur: 28 * unit, color: CGColor(gray: 0, alpha: 0.6))
    context.addPath(flapPath())
    context.setFillColor(pageGradient[0])
    context.fillPath()
    context.restoreGState()
    context.restoreGState()

    // The flap: lighter than the page, brightest at the cut.
    context.saveGState()
    context.addPath(flapPath())
    context.clip()
    let white = CGColor(gray: 1, alpha: 1)
    context.drawLinearGradient(
        CGGradient(colorsSpace: p3, colors: [
            blend(pageGradient[0], toward: white, by: 0.16),
            blend(pageGradient[0], toward: white, by: 0.04),
        ] as CFArray, locations: [0, 1])!,
        start: CGPoint(x: (foldX + page.maxX) / 2 + 20, y: (page.minY + foldY) / 2 - 20),
        end: CGPoint(x: foldX, y: foldY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()

    // Grain on the page and the flap, one speck per device pixel. The glass
    // glyph keeps clear of it.
    if let grain = grain(pixels: pixels) {
        context.saveGState()
        context.addPath(pagePath())
        context.clip()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.interpolationQuality = .none
        context.draw(grain, in: CGRect(x: 0, y: 0, width: iconCanvas, height: iconCanvas))
        context.interpolationQuality = .high
        context.setBlendMode(.destinationOut)
        context.translateBy(x: 0, y: glyph.rect.maxY + glyph.rect.minY)
        context.scaleBy(x: 1, y: -1)
        context.draw(glyph.coverage, in: glyph.rect)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    // A rim, so that the page keeps its edge on a dark window: light at the
    // top, as glass catches the light, and fading down the sides.
    context.saveGState()
    context.addPath(pagePath())
    context.clip()
    context.addPath(pagePath())
    context.setLineWidth(max(3, 1.5 / unit))
    context.replacePathWithStrokedPath()
    context.clip()
    context.drawLinearGradient(
        CGGradient(colorsSpace: p3, colors: [
            CGColor(gray: 1, alpha: 0.28),
            CGColor(gray: 1, alpha: 0.08),
            CGColor(gray: 1, alpha: 0.12),
        ] as CFArray, locations: [0, 0.5, 1])!,
        start: CGPoint(x: 0, y: page.minY), end: CGPoint(x: 0, y: page.maxY), options: []
    )
    context.restoreGState()

    return context.makeImage()!
}

// MARK: - The iconset

try? FileManager.default.removeItem(at: outURL)
try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        let destination = CGImageDestinationCreateWithURL(
            outURL.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, render(pixels: points * factor), nil)
        guard CGImageDestinationFinalize(destination) else { fail("cannot write \(name)") }
    }
}
