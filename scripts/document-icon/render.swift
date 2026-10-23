// Draws Macterm's document icon: the page that Finder shows for a file that
// opens with Macterm by default (`CFBundleTypeIconFile` in Info.plist).
//
// The page is the app icon's background with the app icon's pane glyph at its
// top-left. As on the app icon, a grid of characters covers the page, and its
// density is the gradient: heavy characters at the top thin out to dots at the
// bottom, on one flat color. The colors and the glyph's geometry come from
// `Macterm/AppIcon.icon`. The page outline follows the system's generic
// document (`NSWorkspace.icon(for:)` at 1024 px, measured on macOS 27).
//
// The glyph is real Liquid Glass. `macterm-icon-renderer` (the adaptive
// icon's helper) draws the whole app icon on the page's own background, and
// this script crops the glyph out with soft edges. Glass shows what is behind
// it, so a glyph that is cut out with a transparency would show a different
// background on the page. A crop of a render on the page's own background
// needs no transparency: its background is the page.
//
// The page's characters must be behind that glass too. The script compiles its
// own copy of the icon, with the character layer replaced by the page's grid
// moved onto the icon's canvas: the same characters at the same places. The
// glass then refracts the characters that surround it, and the crop meets the
// page with no seam.
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

/// `color` moved `amount` of the way to `target`, in Display P3. An amount
/// outside 0…1 extrapolates.
func blend(_ color: CGColor, toward target: CGColor, by amount: Double) -> CGColor {
    let from = color.converted(to: p3, intent: .defaultIntent, options: nil)!.components!
    let to = target.converted(to: p3, intent: .defaultIntent, options: nil)!.components!
    let mixed: [CGFloat] = (0 ..< 3).map { from[$0] + (to[$0] - from[$0]) * amount } + [1]
    return CGColor(colorSpace: p3, components: mixed)!
}

// MARK: - The characters

/// The character grid of the page, as `scripts/app-icon/characters.swift`
/// draws the app icon's: the same ramp, alpha, density and dither. The cells
/// are a little smaller, so that the page has about as many rows as the icon.
enum Characters {
    static let ramp = Array(" .:-=+*#%@")
    static let alpha = 0.32
    static let cellHeight = 64.0
    static let densityTop = 0.85
    static let densityBottom = 0.05
    static let dither = 3.0
    static let seed: UInt64 = 3
}

/// The characters' color: the fill of the app icon's Characters group.
guard let charactersGroup = icon.groups.first(where: { $0.name == "Characters" }),
      let charactersFill = charactersGroup.layers.first?.fill.solid
else { fail("expected a Characters group in icon.json") }
let charactersColor = color(charactersFill).copy(alpha: Characters.alpha)!

/// A random value in 0..<1 for each cell.
func hash(_ x: Int, _ y: Int) -> Double {
    var h = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F ^ Characters.seed
    h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
    h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
    h ^= h >> 31
    return Double(h >> 11) / Double(1 << 53)
}

let characterFont = CTFontCreateWithName("SFMono-Medium" as CFString, Characters.cellHeight * 0.8, nil)
let cellWidth: Double = {
    var glyph = CGGlyph()
    var advance = CGSize.zero
    var letter = UniChar(UInt8(ascii: "M"))
    CTFontGetGlyphsForCharacters(characterFont, &letter, &glyph, 1)
    CTFontGetAdvancesForGlyphs(characterFont, .horizontal, &glyph, &advance, 1)
    return Double(advance.width)
}()

/// Draws the page's characters in page points, y down, in `color`. The
/// context maps page points to its own space.
func drawCharacters(in context: CGContext, color: CGColor) {
    let rows = Int((page.height / Characters.cellHeight).rounded(.up))
    let columns = Int((page.width / cellWidth).rounded(.up))
    for row in 0 ... rows {
        for column in 0 ... columns {
            let top = page.minY + Double(row) * Characters.cellHeight
            let t = (top - page.minY + Characters.cellHeight / 2) / page.height
            let density = Characters.densityTop + (Characters.densityBottom - Characters.densityTop) * t
            let step = density * Double(Characters.ramp.count - 1) + (hash(column, row) - 0.5) * Characters.dither
            let character = Characters.ramp[max(0, min(Characters.ramp.count - 1, Int(step.rounded())))]
            if character == " " { continue }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: [
                kCTFontAttributeName as NSAttributedString.Key: characterFont,
                kCTForegroundColorAttributeName as NSAttributedString.Key: color,
            ]))
            // CoreText draws y up: flip around the baseline.
            context.saveGState()
            context.translateBy(x: page.minX + Double(column) * cellWidth, y: top + Characters.cellHeight * 0.8)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
}

/// The page's characters on the app icon's canvas, as a mask for the
/// Characters layer: 2 pixels a point, so the layer's scale is 0.5.
func charactersMask() -> CGImage {
    let pixels = Int(iconCanvas * 2)
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Canvas points, y down; then page points onto the canvas, the inverse of `onPage`.
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: 2, y: -2)
    context.translateBy(x: glyphBounds.minX, y: glyphBounds.minY)
    context.scaleBy(x: 1 / glyphScale, y: 1 / glyphScale)
    context.translateBy(x: -glyphOrigin.x, y: -glyphOrigin.y)
    drawCharacters(in: context, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: Characters.alpha))
    return context.makeImage()!
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

func requestColor(_ color: CGColor) -> [String: Double] {
    let components = color.converted(to: sRGB, intent: .defaultIntent, options: nil)!.components!
    return ["red": components[0], "green": components[1], "blue": components[2]]
}

/// Compiles a copy of the icon with the page's characters in place of its own,
/// as Xcode compiles the app's, and returns the path of the catalog.
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
        for group in groups.indices where groups[group]["name"] as? String == "Characters" {
            guard var layers = groups[group]["layers"] as? [[String: Any]] else { continue }
            for layer in layers.indices where layers[layer]["name"] as? String == "ascii" {
                layers[layer]["image-name"] = "page-characters.png"
                layers[layer]["position"] = ["scale": 0.5, "translation-in-points": [0, 0]]
            }
            groups[group]["layers"] = layers
        }
        document["groups"] = groups
        let maskURL = copy.appendingPathComponent("Assets/page-characters.png")
        guard let destination = CGImageDestinationCreateWithURL(maskURL as CFURL, "public.png" as CFString, 1, nil)
        else { fail("cannot write \(maskURL.path)") }
        CGImageDestinationAddImage(destination, charactersMask(), nil)
        guard CGImageDestinationFinalize(destination) else { fail("cannot write \(maskURL.path)") }
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

/// The app icon in real glass, from the helper, on the page's background.
func renderGlassIcon() -> CGImage {
    let request: [String: Any] = [
        "catalogPath": catalogPath,
        "iconName": "AppIcon",
        "appearance": "dark",
        "backgroundTop": requestColor(background),
        "backgroundBottom": requestColor(background),
        // Bottom to top, as `AdaptiveIconRequest.layers`: the reverse of `groups`.
        "layers": icon.groups.reversed().map { requestColor(color($0.layers[0].fill.solid!)) },
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

/// The smooth step from 0 at `low` to 1 at `high`.
func smoothStep(_ low: Double, _ high: Double, _ value: Double) -> Double {
    let t = min(1, max(0, (value - low) / (high - low)))
    return t * t * (3 - 2 * t)
}

/// The glass glyph on the page.
struct Glyph {
    /// The crop of the render on the page's background, faded in from its edges.
    var image: CGImage
    /// The crop's rect on the page.
    var rect: CGRect
}

func glassGlyph() -> Glyph {
    let render = renderGlassIcon()

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
    guard let crop = render.cropping(to: pixelCrop) else { fail("cannot crop the render") }
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

    let topLeft = onPage(glyphCrop.origin)
    let bottomRight = onPage(CGPoint(x: glyphCrop.maxX, y: glyphCrop.maxY))
    return Glyph(
        image: faded,
        rect: CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    )
}

let glyph = glassGlyph()

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
    context.setFillColor(background)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(pagePath())
    context.clip()
    drawCharacters(in: context, color: charactersColor)

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
    context.setFillColor(background)
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
            blend(background, toward: white, by: 0.16),
            blend(background, toward: white, by: 0.04),
        ] as CFArray, locations: [0, 1])!,
        start: CGPoint(x: (foldX + page.maxX) / 2 + 20, y: (page.minY + foldY) / 2 - 20),
        end: CGPoint(x: foldX, y: foldY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.restoreGState()

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
