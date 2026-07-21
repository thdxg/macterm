import AppKit

extension NSColor {
    /// Black or white, whichever provides the stronger WCAG contrast against
    /// this color. Comparing contrast directly handles vivid colors correctly;
    /// a simple RGB brightness threshold misclassifies saturated reds and
    /// magentas as dark even when black text is substantially more legible.
    var contrastingMonochromeColor: NSColor {
        NSColor.black.contrastRatio(with: self) >= NSColor.white.contrastRatio(with: self) ? .black : .white
    }

    var prefersDarkForeground: Bool {
        contrastingMonochromeColor == .black
    }

    func isVisuallyEqual(to other: NSColor, tolerance: CGFloat = 2.0 / 255.0) -> Bool {
        distance(to: other) <= tolerance
    }

    func distance(to other: NSColor) -> CGFloat {
        guard let lhs = usingColorSpace(.sRGB), let rhs = other.usingColorSpace(.sRGB) else {
            return .greatestFiniteMagnitude
        }
        let red = lhs.redComponent - rhs.redComponent
        let green = lhs.greenComponent - rhs.greenComponent
        let blue = lhs.blueComponent - rhs.blueComponent
        return sqrt(red * red + green * green + blue * blue)
    }

    func contrastRatio(with other: NSColor) -> CGFloat {
        let lighter = max(wcagLuminance, other.wcagLuminance)
        let darker = min(wcagLuminance, other.wcagLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private var wcagLuminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }
}
