// Draws Macterm's document icon: the page that Finder shows for a file that
// opens with Macterm by default (`CFBundleTypeIconFile` in Info.plist).
//
// The page is the app icon's screen, in the page's shape, with none of its
// cross: one glass pane over the whole page. Behind the glass, a grid of
// characters covers the page, and its density is the gradient: heavy
// characters at the top thin out to dots at the bottom, in one color. The
// colors come from `Macterm/AppIcon.icon`. The page outline
// follows the system's generic document (`NSWorkspace.icon(for:)` at 1024 px,
// measured on macOS 27).
//
// The page is real Liquid Glass. The script compiles its own copy of the icon,
// with the pane and the characters drawn again for the page, and without the
// cross, its shade and the screen's gradient (`leftOut`): in a region of the
// icon's canvas with the page's shape, inside the frames.
// `macterm-icon-renderer` (the adaptive icon's helper) draws that copy, and the
// script lays the region over the page.
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

/// The layers of the app icon that the page leaves out: the cross, its shade
/// and the screen's gradient. Each group keeps at least one layer, so the copy
/// has the app icon's groups, as the helper requires.
func leftOut(_ name: String) -> Bool {
    name.hasPrefix("cross") || name == "screen-gradient"
}
/// The app icon's background: one flat color.
guard let solidFill = icon.fill.solid else { fail("expected a solid background in icon.json") }
let background = color(solidFill)

/// The icon canvas is 1024 pt.
let iconCanvas = 1024.0
// MARK: - The page, on a 1024 canvas, y down

let page = CGRect(x: 168, y: 58, width: 688, height: 908)
/// The page's corners, and the two corners where the page meets the fold,
/// measured on the system's generic document at 1024 px: its corners fit a
/// 28 pt circle, and the fold's ends a 60 pt one, which makes the fold soft.
let cornerRadius = 28.0
let foldCornerRadius = 60.0
/// The fold starts on the top edge at `foldX` and ends on the right edge at
/// `foldY`: a 45° cut, as on the system's page.
let foldX = 604.0
let foldY = page.minY + (page.maxX - foldX)
/// The flap's inner corner: the corner of the flap away from the fold.
let foldRadius = 28.0

/// The region of the app icon's canvas that becomes the page: the page's
/// shape, inside the frames, so that no ring shows.
let regionHeight = 800.0
let region = CGRect(
    x: iconCanvas / 2 - regionHeight * page.width / page.height / 2, y: (iconCanvas - regionHeight) / 2,
    width: regionHeight * page.width / page.height, height: regionHeight
)
let regionScale = region.height / page.height

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
/// draws the app icon's: the same ramp, density, dither and spacing. The
/// cells are smaller, so that the page has more rows than the icon.
enum Characters {
    static let ramp: [[String]] = [
        [" "], [".", "·"], [":", "␣", "-"], ["⌃", "+", "="], ["⌥", "*", "←"],
        ["⇧", "⏎", "⇥"], ["#", "⌫", "⎋"], ["%", "@", "⌦"], ["⌘"],
    ]
    static let spacing = 1.6
    static let cellHeight = 64.0
    static let densityTop = 0.85
    static let densityBottom = 0.05
    static let dither = 3.0
    static let seed: UInt64 = 3
}

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
    return Double(advance.width) * Characters.spacing
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
            let level = Characters.ramp[max(0, min(Characters.ramp.count - 1, Int(step.rounded())))]
            let character = level[Int(hash(column + 7, row + 13) * Double(level.count)) % level.count]
            if character == " " { continue }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: character, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: characterFont,
                kCTForegroundColorAttributeName as NSAttributedString.Key: color,
            ]))
            // CoreText draws y up: flip around the baseline. Each character's
            // ink is centered in its cell, as in the app icon, so the rows
            // and the columns line up.
            context.saveGState()
            context.translateBy(x: page.minX + Double(column) * cellWidth, y: top + Characters.cellHeight * 0.8)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            let ink = CTLineGetImageBounds(line, context)
            context.textPosition = CGPoint(
                x: cellWidth / Characters.spacing / 2 - ink.midX,
                y: Characters.cellHeight * 0.28 - ink.midY
            )
            CTLineDraw(line, context)
            context.restoreGState()
        }
    }
}

// MARK: - The masks of the compiled copy

/// A mask for a layer of a group of scale 0.58 (2 pixels a point, layer scale
/// 0.5 / 0.58) or of the Characters group (scale 1, layer scale 0.5). `draw`
/// draws in page points, y down, which land in the page's region of the canvas.
func pageMask(_ draw: (CGContext) -> Void) -> CGImage {
    let pixels = Int(iconCanvas * 2)
    let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Canvas points, y down; then page points onto the region.
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: 2, y: -2)
    context.translateBy(x: region.minX, y: region.minY)
    context.scaleBy(x: regionScale, y: regionScale)
    context.translateBy(x: -page.minX, y: -page.minY)
    context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    draw(context)
    return context.makeImage()!
}

/// The page's characters.
func charactersMask() -> CGImage {
    pageMask { drawCharacters(in: $0, color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)) }
}

/// The pane: the whole page and past it, so that its edges are outside the
/// page and nothing in the page is bent.
func paneMask() -> CGImage {
    pageMask { $0.fill(CGRect(x: -2 * iconCanvas, y: -2 * iconCanvas, width: 5 * iconCanvas, height: 5 * iconCanvas)) }
}

// MARK: - The glass page

/// The render's edge, in pixels. The page's region comes out about 1290 px
/// high, more than the 908 px of the largest document icon.
let renderPixels = 2048

func requestColor(_ color: CGColor) -> [String: Double] {
    let components = color.converted(to: sRGB, intent: .defaultIntent, options: nil)!.components!
    return ["red": components[0], "green": components[1], "blue": components[2]]
}

/// Compiles a copy of the icon with the page's pane and characters in
/// place of its own, as Xcode compiles the app's, and returns the path of the
/// catalog.
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
        let masks: [String: CGImage] = ["ascii": charactersMask(), "glass-pane": paneMask()]
        for group in groups.indices {
            guard var layers = groups[group]["layers"] as? [[String: Any]],
                  let groupScale = (groups[group]["position"] as? [String: Any])?["scale"] as? Double
            else { continue }
            layers.removeAll { leftOut($0["name"] as? String ?? "") }
            for layer in layers.indices {
                guard let name = layers[layer]["name"] as? String, masks[name] != nil else { continue }
                layers[layer]["image-name"] = "page-\(name).png"
                // Each mask is 2048 px over the 1024 pt canvas.
                layers[layer]["position"] = ["scale": 0.5 / groupScale, "translation-in-points": [0, 0]]
            }
            groups[group]["layers"] = layers
        }
        document["groups"] = groups
        for (name, image) in masks {
            let maskURL = copy.appendingPathComponent("Assets/page-\(name).png")
            guard let destination = CGImageDestinationCreateWithURL(maskURL as CFURL, "public.png" as CFString, 1, nil)
            else { fail("cannot write \(maskURL.path)") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { fail("cannot write \(maskURL.path)") }
        }
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

/// The copy of the icon in real glass, from the helper, on the page's background.
func renderGlassIcon() -> CGImage {
    let request: [String: Any] = [
        "catalogPath": catalogPath,
        "iconName": "AppIcon",
        "appearance": "dark",
        "backgroundTop": requestColor(background),
        "backgroundBottom": requestColor(background),
        // Bottom to top, as `AdaptiveIconRequest.layers`: the reverse of
        // `groups`. Each group takes the fill of the first layer it keeps,
        // or keeps its own fills when that fill is not a solid color (the
        // frames' gradients).
        "layers": icon.groups.reversed().map { group -> Any in
            guard let solid = group.layers.first(where: { !leftOut($0.name) })!.fill.solid else { return NSNull() }
            return requestColor(color(solid))
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

/// The page's region of the render: the whole page, in glass.
let glassPage: CGImage = {
    let render = renderGlassIcon()
    // Where the helper puts the body: `IconCanvas` in IconRenderer/main.swift.
    let canvas = Double(renderPixels)
    let body = (canvas * 824 / 1024).rounded()
    let inset = ((canvas - body) / 2).rounded()
    let unit = body / iconCanvas
    let pixelRegion = CGRect(
        x: inset + region.minX * unit, y: inset + region.minY * unit,
        width: region.width * unit, height: region.height * unit
    ).integral
    guard let crop = render.cropping(to: pixelRegion) else { fail("cannot crop the render") }
    return crop
}()

// MARK: - Drawing

func pagePath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: page.minX, y: page.midY))
    path.addArc(tangent1End: CGPoint(x: page.minX, y: page.minY), tangent2End: CGPoint(x: foldX, y: page.minY), radius: cornerRadius)
    path.addArc(tangent1End: CGPoint(x: foldX, y: page.minY), tangent2End: CGPoint(x: page.maxX, y: foldY), radius: foldCornerRadius)
    path.addArc(tangent1End: CGPoint(x: page.maxX, y: foldY), tangent2End: CGPoint(x: page.maxX, y: page.maxY), radius: foldCornerRadius)
    path.addArc(tangent1End: CGPoint(x: page.maxX, y: page.maxY), tangent2End: CGPoint(x: page.minX, y: page.maxY), radius: cornerRadius)
    path.addArc(tangent1End: CGPoint(x: page.minX, y: page.maxY), tangent2End: CGPoint(x: page.minX, y: page.minY), radius: cornerRadius)
    path.closeSubpath()
    return path
}

/// The folded-over corner: the triangle that the cut removed, flipped onto the
/// page. Its two sharp tips are the ends of the fold, on the page's edge, so
/// the flap stays joined to the page along the fold. Rounding a 45° tip cuts it
/// far back and leaves the flap floating; the page's own rounded cut corners
/// round the tips instead, because the flap is drawn clipped to the page.
func flapPath() -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: foldX, y: page.minY))
    path.addArc(tangent1End: CGPoint(x: foldX, y: foldY), tangent2End: CGPoint(x: page.maxX, y: foldY), radius: foldRadius)
    path.addLine(to: CGPoint(x: page.maxX, y: foldY))
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

    // The glass page. The image is y down; draw it flipped back.
    context.saveGState()
    context.translateBy(x: 0, y: page.maxY + page.minY)
    context.scaleBy(x: 1, y: -1)
    context.draw(glassPage, in: page)
    context.restoreGState()

    // The fold casts its shadow onto the page.
    context.saveGState()
    // Down and to the left, soft, as on the system's page.
    context.setShadow(offset: CGSize(width: -6 * unit, height: -14 * unit), blur: 44 * unit, color: CGColor(gray: 0, alpha: 0.6))
    context.addPath(flapPath())
    context.setFillColor(background)
    context.fillPath()
    context.restoreGState()
    context.restoreGState()

    // The flap: lighter than the page. As on the system's page, it is darkest
    // along the fold and brightest at its inner corner.
    context.saveGState()
    context.addPath(pagePath())
    context.clip()
    context.addPath(flapPath())
    context.clip()
    let white = CGColor(gray: 1, alpha: 1)
    context.drawLinearGradient(
        CGGradient(colorsSpace: p3, colors: [
            blend(background, toward: white, by: 0.04),
            blend(background, toward: white, by: 0.16),
        ] as CFArray, locations: [0, 1])!,
        start: CGPoint(x: (foldX + page.maxX) / 2, y: (page.minY + foldY) / 2),
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
