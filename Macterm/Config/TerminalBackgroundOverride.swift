import AppKit

/// Chooses whether Ghostty owns the terminal background or Macterm writes a
/// last-wins background override into its generated config.
enum TerminalBackgroundSource: String, CaseIterable, Identifiable {
    case ghosttyConfig = "ghostty_config"
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ghosttyConfig: "Use Ghostty config"
        case .custom: "Override with custom color"
        }
    }
}

/// Stable, color-space-independent representation of a user-selected terminal
/// background. UserDefaults stores the canonical `#RRGGBB` value rather than
/// archiving an NSColor whose color space can vary across displays and OSes.
struct TerminalBackgroundColor: Equatable {
    static let defaultValue = TerminalBackgroundColor(red: 0x19, green: 0x17, blue: 0x24)

    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: 1
        )
    }

    /// Custom-background mode owns the default terminal foreground too, using
    /// the monochrome color with the stronger WCAG contrast. ANSI palette
    /// colors remain untouched, so the rest of the user's theme is preserved.
    var foregroundHex: String {
        nsColor.prefersDarkForeground ? "#000000" : "#FFFFFF"
    }

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(hex: String) {
        let value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard digits.count == 6, let packed = UInt32(digits, radix: 16) else { return nil }
        red = UInt8((packed >> 16) & 0xFF)
        green = UInt8((packed >> 8) & 0xFF)
        blue = UInt8(packed & 0xFF)
    }

    init?(nsColor: NSColor) {
        guard let srgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        red = Self.byte(srgb.redComponent)
        green = Self.byte(srgb.greenComponent)
        blue = Self.byte(srgb.blueComponent)
    }

    private static func byte(_ component: CGFloat) -> UInt8 {
        UInt8((max(0, min(1, component)) * 255).rounded())
    }
}

enum TerminalBackgroundOverride {
    static func configLines(source: TerminalBackgroundSource, color: TerminalBackgroundColor) -> [String] {
        guard source == .custom else { return [] }
        return [
            "background = \(color.hex)",
            "foreground = \(color.foregroundHex)",
        ]
    }
}
