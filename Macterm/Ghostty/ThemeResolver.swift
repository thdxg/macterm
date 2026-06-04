import Foundation

/// Resolves ghostty's `theme = light:X,dark:Y` split syntax for Macterm's own
/// chrome (window, sidebar, palette — everything driven by `MactermTheme`).
///
/// libghostty applies the active color scheme only to the terminal *surface* at
/// render time (`ghostty_surface_set_color_scheme`); the surface re-resolves a
/// split on its own when the OS appearance changes. But the config object's
/// color getters (`ghostty_config_get("background")`, palette, …) always
/// resolve a split to the `light:` side and never consult the OS appearance,
/// and the raw `theme` value isn't readable back through the C API. So for the
/// chrome — which derives from those getters — Macterm has to pick the side
/// itself and read the chosen theme file's colors directly. A plain (non-split)
/// `theme` resolves correctly through libghostty's getters already, so the
/// chrome falls back to them in that case. (Issue #38.)
enum ThemeResolver {
    /// The side of a `light:`/`dark:` split to pick.
    enum Scheme {
        case light
        case dark
    }

    /// The subset of theme-file colors Macterm's chrome needs.
    struct Colors: Equatable {
        var background: String?
        var foreground: String?
        /// Sparse palette map (index → hex), as found in the theme file.
        var palette: [Int: String]
    }

    /// Given the user's effective `theme` value, return the single theme name
    /// to force for `scheme`, or nil when the value isn't a light/dark split
    /// (libghostty handles plain themes correctly on its own).
    ///
    /// ghostty's split syntax is a comma-separated list of `key:value` pairs
    /// where keys are `light`/`dark`. Order is irrelevant. A value with no
    /// `light:`/`dark:` keys is a plain theme name (which may itself contain
    /// no colon, or be a path) and returns nil.
    static func resolve(themeValue: String, scheme: Scheme) -> String? {
        let trimmed = themeValue.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        var light: String?
        var dark: String?
        for part in trimmed.split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "light": light = value
            case "dark": dark = value
            default: continue
            }
        }

        // Only a real split (at least one recognized key) is ours to resolve.
        guard light != nil || dark != nil else { return nil }
        switch scheme {
        case .light: return light ?? dark
        case .dark: return dark ?? light
        }
    }

    /// Extract the effective `theme` value from ghostty config text, honoring
    /// last-wins like libghostty's own merge. Returns nil when no `theme =`
    /// line is present. Comments (`#`) and blank lines are ignored.
    static func themeValue(inConfigText text: String) -> String? {
        var result: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex ..< eq].trimmingCharacters(in: .whitespaces)
            guard key == "theme" else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            // ghostty allows quoting theme names with spaces; strip a matched
            // pair of surrounding double quotes.
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { result = value }
        }
        return result
    }

    /// Parse the `background`, `foreground`, and `palette` entries out of a
    /// ghostty theme file's text. Theme files are plain `key = value` ghostty
    /// config fragments (e.g. `background = #191724`, `palette = 0=#26233a`).
    static func colors(inThemeFile text: String) -> Colors {
        var bg: String?
        var fg: String?
        var palette: [Int: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex ..< eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": bg = value
            case "foreground": fg = value
            case "palette":
                // value is "<index>=<hex>"
                let parts = value.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let idx = Int(parts[0].trimmingCharacters(in: .whitespaces)) {
                    palette[idx] = parts[1].trimmingCharacters(in: .whitespaces)
                }
            default: continue
            }
        }
        return Colors(background: bg, foreground: fg, palette: palette)
    }
}
