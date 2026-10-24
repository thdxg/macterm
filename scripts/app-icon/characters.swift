// Draws the character layers of the app icon:
// Macterm/AppIcon.icon/Assets/ascii.png, and one copy of it for each corner
// of the mesh gradient, ascii-<corner>.png.
//
// The layer is a monospace grid of characters over the whole canvas, under
// all the glass. Its density is the icon's gradient: heavy characters at the
// top thin out to dots at the bottom, on a flat background. Each cell takes a
// step of the ramp by its height, with a random offset of up to `dither` steps,
// so that the rows mix and no bands show, and then one character of that step.
// The steps mix Mac key symbols (⌃ ⌥ ⇧ ⏎ ⇥ ⌫ ⎋ ⌦ ⌘) with ASCII, in order of
// their ink. Icon Composer fills the mask with one color, so only the alpha
// counts.
//
// SF Mono has most of the symbols. ⎋ and ⇥ come from Menlo, CoreText's
// fallback, which keeps the grid. ⎇ is left out: its fallback is twice as
// wide as a cell.
//
// A seeded generator picks the offsets, so a run with no change here writes
// the same file.
//
// The mesh gradient: each copy is the characters faded by a soft Gaussian blob
// at one place near the edge (`corners`). The copies are flat layers over the
// characters, and each takes one ANSI color of the theme. They blend as the
// colors of a mesh gradient do. They must be flat: a glass layer traces its
// edge where its alpha crosses a threshold, and a fade made that edge a ring.
//
// Usage: swift scripts/app-icon/characters.swift <AppIcon.icon/Assets>

import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// The alpha of every character.
let alpha = 1.0
/// The height of a cell in canvas points. The font is 80% of it.
let cellHeight = 144.0
/// The density at the top and at the bottom, from 0 (space) to 1 (@).
let densityTop = 0.85
let densityBottom = 0.05
/// How many steps of the ramp the random offset spans.
let dither = 3.0
/// The column pitch, in character widths: the letter spacing.
let spacing = 1.6
let seed: UInt64 = 3
let size = 1024
/// The steps of the ramp, from no ink to the most. A cell picks one
/// character of its step.
let ramp: [[String]] = [
    [" "], [".", "·"], [":", "␣", "-"], ["⌃", "+", "="], ["⌥", "*", "←"],
    ["⇧", "⏎", "⇥"], ["#", "⌫", "⎋"], ["%", "@", "⌦"], ["⌘"],
]

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: characters.swift <AppIcon.icon/Assets>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

/// Where each copy is brightest, in canvas points down from the top-left,
/// and how wide its blob is (the standard deviation).
let corners: [(name: String, x: Double, y: Double)] = [
    ("top-left", 130, 130), ("top-right", 894, 130), ("left", 80, 540), ("right", 944, 540), ("bottom-left", 130, 930),
]
let blobWidth = 230.0

/// A random value in 0..<1 for each cell.
func hash(_ x: Int, _ y: Int) -> Double {
    var h = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F ^ seed
    h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
    h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
    h ^= h >> 31
    return Double(h >> 11) / Double(1 << 53)
}

let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
let font = CTFontCreateWithName("SFMono-Medium" as CFString, cellHeight * 0.8, nil)
var glyph = CGGlyph()
var advance = CGSize.zero
var letter = UniChar(UInt8(ascii: "M"))
CTFontGetGlyphsForCharacters(font, &letter, &glyph, 1)
CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
let cellWidth = Double(advance.width) * spacing
let color = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)

for row in 0 ... Int(Double(size) / cellHeight) {
    for column in 0 ... Int(Double(size) / cellWidth) {
        // y down for the density; CoreText draws y up.
        let x = Double(column) * cellWidth
        let yDown = Double(row) * cellHeight
        let t = (yDown + cellHeight / 2) / Double(size)
        let density = densityTop + (densityBottom - densityTop) * t
        let step = density * Double(ramp.count - 1) + (hash(column, row) - 0.5) * dither
        let level = ramp[max(0, min(ramp.count - 1, Int(step.rounded())))]
        let character = level[Int(hash(column + 7, row + 13) * Double(level.count)) % level.count]
        if character == " " { continue }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: character, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color,
        ]))
        context.textPosition = CGPoint(x: x, y: Double(size) - yDown - cellHeight * 0.8)
        CTLineDraw(line, context)
    }
}

func write(_ image: CGImage, _ name: String) {
    let url = outDir.appendingPathComponent("\(name).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
}

let characters = context.makeImage()!
write(characters, "ascii")

/// A gray Gaussian blob, white at its center: the copy's alpha.
func blob(x: Double, y: Double) -> CGImage {
    let gray = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
    )!
    let stops = 16
    let radius = 3 * blobWidth
    let locations = (0 ..< stops).map { CGFloat($0) / CGFloat(stops - 1) }
    let components = locations.flatMap { t -> [CGFloat] in
        let d = Double(t) * radius
        return [CGFloat(exp(-d * d / (2 * blobWidth * blobWidth))), 1]
    }
    let gradient = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: components, locations: locations, count: stops)!
    // CoreGraphics runs y up.
    let center = CGPoint(x: x, y: Double(size) - y)
    gray.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    return gray.makeImage()!
}

for corner in corners {
    let copy = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    copy.clip(to: rect, mask: blob(x: corner.x, y: corner.y))
    copy.draw(characters, in: rect)
    write(copy.makeImage()!, "ascii-\(corner.name)")
}
