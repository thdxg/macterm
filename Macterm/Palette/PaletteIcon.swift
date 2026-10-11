import AppKit
import SwiftUI

/// What a palette row, a pill or an extension card draws at its leading
/// edge: an SF Symbol, or the icon file that an extension bundles
/// (`MactermExtension.iconFile`). A string literal is a symbol.
///
/// An icon file is held as its bytes, which the store read and checked
/// when it loaded the extension. A view never reads a file, and an edit
/// to the file shows on the next reload, as an edit to a palette does.
enum PaletteIcon: Hashable, ExpressibleByStringLiteral {
    case symbol(String)
    /// A PNG of exactly `MactermExtension.iconPixelSize`.
    case image(Data)

    init(stringLiteral value: String) {
        self = .symbol(value)
    }
}

/// A `PaletteIcon` at the size of the text around it. A symbol takes the
/// font and the foreground style of its context. An icon file draws as a
/// template image: its alpha is the shape, and the foreground style is
/// the color, as for a symbol and a bundled agent logo (`AgentIcon`). So
/// every glyph in the palette has the same weight, in light and dark mode.
struct PaletteIconImage: View {
    let icon: PaletteIcon
    /// The edge of the square that an icon file fills. A symbol sizes itself
    /// from the font.
    var side: CGFloat = 16

    var body: some View {
        switch icon {
        case let .symbol(name):
            Image(systemName: name)
        case let .image(data):
            if let image = PaletteIconCache.image(for: data) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
            } else {
                Image(systemName: MactermExtension.defaultIcon)
            }
        }
    }
}

/// Decoded icon files, by their bytes. A palette draws its rows again on
/// each keystroke, and an icon file is a few kilobytes, so each one is
/// decoded one time.
@MainActor
private enum PaletteIconCache {
    private static var images: [Data: NSImage] = [:]

    static func image(for data: Data) -> NSImage? {
        if let image = images[data] { return image }
        guard let image = NSImage(data: data) else { return nil }
        image.isTemplate = true
        // The bitmap is 2x: draw it at half its pixels, so that it is sharp
        // on a Retina display and the same size on any other.
        image.size = NSSize(width: MactermExtension.iconPixelSize / 2, height: MactermExtension.iconPixelSize / 2)
        images[data] = image
        return image
    }
}
