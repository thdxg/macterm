// Draws the character layer of the app icon:
// Macterm/AppIcon.icon/Assets/ascii.png.
//
// The layer is a monospace grid of characters under all the glass. Each of
// the four panes has a grid of its own, as a terminal pane does: it starts
// `margin` from the cross and runs outward, past the icon's edge, so the
// characters run on under the frames. Every cell is drawn, clipped to its
// pane, so the characters reach the rounded corners where the arms meet.
//
// The margin keeps the characters out of the band where the panes' glass
// bends them. The glass pulls squeezed copies of nearby characters into that
// band, and a character in it lost its place in the grid.
//
// The density is the icon's gradient: heavy characters at the top thin out to
// dots at the bottom, on a flat background. Each cell takes a step of the ramp
// by its height, with a random offset of up to `dither` steps, so that the
// rows mix and no bands show, and then one character of that step. The steps
// mix Mac key symbols (⌃ ⌥ ⇧ ⏎ ⇥ ⌫ ⎋ ⌦ ⌘) with ASCII, in order of their ink.
// Icon Composer fills the mask with one color, so only the alpha counts.
//
// SF Mono has most of the symbols. ⎋ and ⇥ come from Menlo, CoreText's
// fallback, which keeps the grid. ⎇ is left out: its fallback is twice as
// wide as a cell.
//
// A seeded generator picks the offsets, so a run with no change here writes
// the same file.
//
// Usage: swift scripts/app-icon/characters.swift <AppIcon.icon/Assets>

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SwiftUI

/// The alpha of every character.
let alpha = 1.0
/// The height of a cell in canvas points. The font is 80% of it.
let cellHeight = 120.0
/// The space between the characters and the cross, in canvas points: wider
/// than the band where the panes' glass bends the characters.
let margin = 40.0
/// The density at the top and at the bottom, from 0 (space) to 1 (@).
let densityTop = 0.85
let densityBottom = 0.05
/// How many steps of the ramp the random offset spans.
let dither = 3.0
/// The column pitch, in character widths: the letter spacing.
let spacing = 1.6
let seed: UInt64 = 3
let size = 1024
let canvas = 1024.0
/// The steps of the ramp, from no ink to the most. A cell picks one
/// character of its step.
let ramp: [[String]] = [
    [" "], [".", "·"], [":", "␣", "-"], ["⌃", "+", "="], ["⌥", "*", "←"],
    ["⇧", "⏎", "⇥"], ["#", "⌫", "⎋"], ["%", "@", "⌦"], ["⌘"],
]

/// The cross, as `scripts/app-icon/frame.swift` draws it: points down from
/// the top-left, and each quadrant's inner corner radius (the icon's corner
/// radius, 26.15% of the side, less the dark ring's 108 pt inset).
let cross = (x: 597.0, y: 593.0, gap: 52.0, radius: canvas * 0.2615 - 108)
/// The cross's turn, as `frame.swift` draws it: the characters' grids turn
/// clockwise with it, so their rows stay parallel to its arms.
let crossAngle = 8.0

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: characters.swift <AppIcon.icon/Assets>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

/// A random value in 0..<1 for each cell.
func hash(_ x: Int, _ y: Int) -> Double {
    var h = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F ^ seed
    h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
    h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
    h ^= h >> 31
    return Double(h >> 11) / Double(1 << 53)
}

/// The four panes, each `margin` back from the cross, with its inner corner
/// that much less round, so the edge stays concentric with the pane's. Each
/// one runs far past the icon on its outer sides. Points run down from the
/// top-left.
func panePaths() -> [(path: CGPath, left: Bool, top: Bool)] {
    let far = 2 * canvas
    let half = cross.gap / 2 + margin
    let radius = cross.radius - margin
    let panes: [(CGRect, RectangleCornerRadii, Bool, Bool)] = [
        (CGRect(x: -far, y: -far, width: cross.x - half + far, height: cross.y - half + far),
         RectangleCornerRadii(bottomTrailing: radius), true, true),
        (CGRect(x: cross.x + half, y: -far, width: far, height: cross.y - half + far),
         RectangleCornerRadii(bottomLeading: radius), false, true),
        (CGRect(x: -far, y: cross.y + half, width: cross.x - half + far, height: far),
         RectangleCornerRadii(topTrailing: radius), true, false),
        (CGRect(x: cross.x + half, y: cross.y + half, width: far, height: far),
         RectangleCornerRadii(topLeading: radius), false, false),
    ]
    return panes.map { (UnevenRoundedRectangle(cornerRadii: $1, style: .continuous).path(in: $0).cgPath, $2, $3) }
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
let glyphWidth = Double(advance.width)
let cellWidth = glyphWidth * spacing
let color = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha)

/// Draws the cell whose top-left is (x, top), in points down from the top-left.
func drawCell(column: Int, row: Int, x: Double, top: Double) {
    let t = (top + cellHeight / 2) / canvas
    let density = densityTop + (densityBottom - densityTop) * t
    let step = density * Double(ramp.count - 1) + (hash(column, row) - 0.5) * dither
    let level = ramp[max(0, min(ramp.count - 1, Int(step.rounded())))]
    let character = level[Int(hash(column + 7, row + 13) * Double(level.count)) % level.count]
    if character == " " { return }
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: character, attributes: [
        kCTFontAttributeName as NSAttributedString.Key: font,
        kCTForegroundColorAttributeName as NSAttributedString.Key: color,
    ]))
    // Each character's ink is centered in its cell, so the rows and the
    // columns line up: a period sits on the baseline and a caret near the
    // cap height, and the light rows at the bottom looked scattered. The
    // center is where a capital's ink centers, so the heavy characters stay
    // where the baseline put them. CoreText draws y up.
    // The image bounds count from the context's text position.
    context.textPosition = .zero
    let ink = CTLineGetImageBounds(line, context)
    let center = CGPoint(x: x + glyphWidth / 2, y: canvas - top - cellHeight * 0.52)
    context.textPosition = CGPoint(x: center.x - ink.midX, y: center.y - ink.midY)
    CTLineDraw(line, context)
}

// The ink of a cell runs from about 22% of its height (the cap height) to
// 80% (the baseline), and across the character's width.
let leftColumn = cross.x - cross.gap / 2 - margin - glyphWidth
let rightColumn = cross.x + cross.gap / 2 + margin
let topRow = cross.y - cross.gap / 2 - margin - cellHeight * 0.8
let bottomRow = cross.y + cross.gap / 2 + margin - cellHeight * 0.22
let columns = Int(canvas / cellWidth) + 1
let rows = Int(canvas / cellHeight) + 1
var downward = CGAffineTransform(translationX: 0, y: canvas).scaledBy(x: 1, y: -1)
// Turn the panes and their grids about the cross's middle. CoreGraphics runs
// y up, so clockwise is a negative angle.
context.translateBy(x: cross.x, y: canvas - cross.y)
context.rotate(by: -crossAngle * .pi / 180)
context.translateBy(x: -cross.x, y: -(canvas - cross.y))
for pane in panePaths() {
    context.saveGState()
    context.addPath(pane.path.copy(using: &downward)!)
    context.clip()
    for row in 0 ..< rows {
        for column in 0 ..< columns {
            let x = pane.left ? leftColumn - Double(column) * cellWidth : rightColumn + Double(column) * cellWidth
            let top = pane.top ? topRow - Double(row) * cellHeight : bottomRow + Double(row) * cellHeight
            // Columns and rows count out from the cross, negative to the left
            // and up, so that every cell of the four grids has its own seed.
            drawCell(column: pane.left ? -1 - column : column, row: pane.top ? -1 - row : row, x: x, top: top)
        }
    }
    context.restoreGState()
}

func write(_ image: CGImage, _ name: String) {
    let url = outDir.appendingPathComponent("\(name).png")
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { exit(1) }
}

write(context.makeImage()!, "ascii")
