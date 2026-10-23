// Draws the character layer of the app icon:
// Macterm/AppIcon.icon/Assets/ascii.png.
//
// The layer is a monospace grid of characters over the whole canvas, under
// all the glass. Its density is the icon's gradient: heavy characters at the
// top thin out to dots at the bottom, on a flat background. Each cell takes a
// character from the ramp ` .:-=+*#%@` by its height, with a random offset of
// up to `dither` steps, so that the rows mix and no bands show. Icon Composer
// fills the mask with one color (the back pane's), so only the alpha counts.
//
// A seeded generator picks the offsets, so a run with no change here writes
// the same file.
//
// Usage: swift scripts/app-icon/characters.swift <AppIcon.icon/Assets>

import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// The alpha of every character.
let alpha = 0.32
/// The height of a cell in canvas points. The font is 80% of it.
let cellHeight = 72.0
/// The density at the top and at the bottom, from 0 (space) to 1 (@).
let densityTop = 0.85
let densityBottom = 0.05
/// How many steps of the ramp the random offset spans.
let dither = 3.0
let seed: UInt64 = 3
let size = 1024
let ramp = Array(" .:-=+*#%@")

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: characters.swift <AppIcon.icon/Assets>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("ascii.png")

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
let cellWidth = Double(advance.width)
let color = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)

for row in 0 ... Int(Double(size) / cellHeight) {
    for column in 0 ... Int(Double(size) / cellWidth) {
        // y down for the density; CoreText draws y up.
        let x = Double(column) * cellWidth
        let yDown = Double(row) * cellHeight
        let t = (yDown + cellHeight / 2) / Double(size)
        let density = densityTop + (densityBottom - densityTop) * t
        let step = density * Double(ramp.count - 1) + (hash(column, row) - 0.5) * dither
        let character = ramp[max(0, min(ramp.count - 1, Int(step.rounded())))]
        if character == " " { continue }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(character), attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color,
        ]))
        context.textPosition = CGPoint(x: x, y: Double(size) - yDown - cellHeight * 0.8)
        CTLineDraw(line, context)
    }
}

guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { exit(1) }
