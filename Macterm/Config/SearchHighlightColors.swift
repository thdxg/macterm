import Foundation

/// Resolves the colors ghostty's renderer paints search highlights with
/// (`search-background` for candidate matches, `search-selected-background`
/// for the focused one), so the scrollbar ticks match the highlighted text.
///
/// These keys are `TerminalColor` unions in ghostty and that union has no
/// `cval`, so `ghostty_config_get` returns false for them — the resolved
/// values can't be read through the C API. Instead the user's config text is
/// scanned directly, with the same pattern and limitation as
/// `ShellIntegrationFeatures`: last occurrence wins, and a value set in a
/// `config-file` include isn't seen.
enum SearchHighlightColors {
    struct RGB: Equatable {
        let r, g, b: UInt8
    }

    /// Ghostty's documented defaults (`src/config/Config.zig`): candidate
    /// matches on golden yellow, the selected match on soft peach.
    static let defaultMatch = RGB(r: 0xFF, g: 0xE0, b: 0x82)
    static let defaultSelected = RGB(r: 0xF2, g: 0xA5, b: 0x7E)

    static func matchBackground(inConfigText text: String?) -> RGB {
        value(forKey: "search-background", in: text) ?? defaultMatch
    }

    static func selectedBackground(inConfigText text: String?) -> RGB {
        value(forKey: "search-selected-background", in: text) ?? defaultSelected
    }

    /// Last-wins scan for `key = #RRGGBB`. Named X11 colors and
    /// `cell-foreground`/`cell-background` are valid ghostty values a tick
    /// can't reproduce (no X11 table, no per-cell color), so they — like an
    /// empty value, which resets the key — fall back to the default.
    private static func value(forKey key: String, in text: String?) -> RGB? {
        guard let text else { return nil }
        var raw: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            guard line[line.startIndex ..< eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            raw = value
        }
        return raw.flatMap(parseHex)
    }

    private static func parseHex(_ value: String) -> RGB? {
        let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard hex.count == 6, let n = UInt32(hex, radix: 16) else { return nil }
        return RGB(r: UInt8(n >> 16 & 0xFF), g: UInt8(n >> 8 & 0xFF), b: UInt8(n & 0xFF))
    }
}
