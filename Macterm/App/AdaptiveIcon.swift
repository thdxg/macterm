import Foundation

/// The adaptive icon: the Dock and app-switcher icon in the colors of the
/// user's terminal theme, with the bundled icon's own Liquid Glass.
///
/// Pure rules only — what to paint, and whether to paint at all. The render
/// runs in `macterm-icon-renderer` (`AdaptiveIconRenderer`), the write is
/// `AppIconPresenter`, and `AdaptiveIconController` joins them. Every way the
/// render can fail ends on the bundled icon.
enum AdaptiveIcon {
    typealias Color = AdaptiveIconRequest.Color

    /// The theme colors the icon is painted from.
    struct ThemeColors: Equatable {
        var background: Color
        /// The first sixteen palette entries. Every theme has them: ghostty
        /// fills an entry that a theme leaves out with its default.
        var palette: [Color]
    }

    /// The fills of `AppIcon.icon`, in the order the request carries them.
    struct Paint: Equatable {
        var backgroundTop: Color
        var backgroundBottom: Color
        /// Bottom to top: back pane, middle pane, front pane, frame.
        var layers: [Color]
    }

    /// The gray entries (bright white, white, bright black, black), in the
    /// order that breaks a tie.
    static let neutralEntries = [15, 7, 8, 0]
    /// The color entries.
    static let accentEntries = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14]
    /// The smallest step the middle pane keeps from its neighbors, as a share
    /// of the distance from the background to the front pane.
    static let minimumStep = 0.15

    /// The panes as a ramp from the front pane down toward the background,
    /// each pane one palette entry as the theme has it. Distances are OKLab
    /// lightness away from the background, signed by the front pane's side,
    /// so the rule works the same way for a light theme as for a dark one,
    /// and an entry on the far side of a mid-gray background never counts as
    /// a step toward the front.
    ///
    /// - The frame and the front pane are the gray that stands out most from
    ///   the background: palette 15 in most dark themes, palette 0 in a light
    ///   theme whose black is its text color.
    /// - The back pane is another gray, the one nearest 45% of that distance.
    ///   It is nearly always palette 8. Palette 0 is often the background
    ///   itself, and palette 7 is often as bright as palette 15. It must be at
    ///   least `minimumStep` from the background and from the front pane.
    /// - The middle pane is the color entry nearest the middle between the
    ///   back and the front pane, at least `minimumStep` from each. If no
    ///   entry clears both steps, the nearest entry on the front side of the
    ///   back pane.
    /// - The background runs from palette 0 mixed 23% into the background,
    ///   down to the background.
    ///
    /// In eyesclosed, the theme the icon was drawn in, this picks palette 8,
    /// 5 and 15, which are the bundled icon's own fills. Nil when the theme
    /// has no such ramp: no gray differs from the background, no other gray
    /// stands apart from both ends, or no color entry is between the back
    /// and the front pane's side.
    static func paint(for theme: ThemeColors) -> Paint? {
        guard theme.palette.count >= 16 else { return nil }
        let background = lightness(theme.background)
        let offset = theme.palette.prefix(16).map { lightness($0) - background }
        guard let front = first(of: neutralEntries, by: { -abs(offset[$0]) }), abs(offset[front]) > 0.01 else { return nil }
        let share = offset.map { $0 / offset[front] }
        guard let back = first(of: neutralEntries.filter { $0 != front }, by: { abs(share[$0] - 0.45) }),
              share[back] >= minimumStep, share[back] <= 1 - minimumStep
        else { return nil }
        let target = (share[back] + 1) / 2
        let clear = accentEntries.filter { share[$0] <= 1 - minimumStep && share[$0] >= share[back] + minimumStep }
        let candidates = clear.isEmpty ? accentEntries.filter { share[$0] > share[back] } : clear
        guard let middle = first(of: candidates, by: { abs(share[$0] - target) }) else { return nil }
        return Paint(
            backgroundTop: mix(theme.palette[0], into: theme.background, amount: 0.23),
            backgroundBottom: theme.background,
            layers: [theme.palette[back], theme.palette[middle], theme.palette[front], theme.palette[front]]
        )
    }

    /// The entry with the smallest `cost`; the earliest in `entries` on a tie.
    private static func first(of entries: [Int], by cost: (Int) -> Double) -> Int? {
        var best: (entry: Int, cost: Double)?
        for entry in entries {
            let value = cost(entry)
            if let current = best, value >= current.cost - 1e-9 { continue }
            best = (entry, value)
        }
        return best?.entry
    }

    /// OKLab lightness (0 black, 1 white) of an sRGB color.
    static func lightness(_ color: Color) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = linear(color.red), g = linear(color.green), b = linear(color.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    }

    /// `amount` of `color` over `base`, per sRGB component.
    static func mix(_ color: Color, into base: Color, amount: Double) -> Color {
        Color(
            red: base.red + (color.red - base.red) * amount,
            green: base.green + (color.green - base.green) * amount,
            blue: base.blue + (color.blue - base.blue) * amount
        )
    }

    /// The global default that holds the system's icon style (System Settings
    /// → Appearance → Icon & widget style). Absent until the user picks one.
    static let iconStyleKey = "AppleIconAppearanceTheme"

    /// Which stack of the icon to paint, from the system's icon style, or nil
    /// when the adaptive icon must step aside.
    ///
    /// The values are the system's own (`Regular`, `Clear` and `Tinted`, each
    /// alone or with `Light`, `Dark` or `Automatic`). Regular with no side
    /// follows the system appearance, the way the Dock does. Clear and Tinted
    /// get nil: the system draws the bundled icon in those styles itself, and
    /// a theme-colored icon would stand apart from every other icon in the
    /// Dock. A value this rule does not know also gets nil, because the
    /// bundled icon is always right.
    static func appearance(iconStyle: String?, systemScheme: ThemeResolver.Scheme) -> AdaptiveIconRequest.Appearance? {
        let followsSystem: AdaptiveIconRequest.Appearance = systemScheme == .dark ? .dark : .light
        switch iconStyle {
        case nil,
             "Regular",
             "RegularAutomatic": return followsSystem
        case "RegularLight": return .light
        case "RegularDark": return .dark
        default: return nil
        }
    }

    /// What the Dock shows.
    enum Decision: Equatable {
        /// The bundled icon or the user's `macos-icon = custom` image —
        /// whatever the ghostty config asks for (`GhosttyAppIcon`).
        case configured(GhosttyAppIcon)
        /// The bundled icon, repainted in the theme for this stack.
        case adaptive(AdaptiveIconRequest.Appearance)
    }

    /// - Parameters:
    ///   - enabled: `Preferences.adaptiveIcon`.
    ///   - supported: whether this run can render at all (`isSupported`).
    ///   - configured: what the ghostty config asks for. A custom image wins:
    ///     the user named that file on purpose.
    ///   - systemScheme: read only after the setting, the support and the
    ///     configured icon all allow the adaptive icon. The caller reads it
    ///     from `GhosttyApp.shared`, and a run with the icon off (a unit test
    ///     that flips the setting) must not start libghostty for it.
    static func decide(
        enabled: Bool,
        supported: Bool,
        configured: GhosttyAppIcon,
        iconStyle: String?,
        systemScheme: () -> ThemeResolver.Scheme
    ) -> Decision {
        guard enabled, supported, configured == .bundled,
              let appearance = appearance(iconStyle: iconStyle, systemScheme: systemScheme())
        else { return .configured(configured) }
        return .adaptive(appearance)
    }

    /// The icon is Liquid Glass, which only macOS 26 and later draw. Hermetic
    /// runs (tests, `MACTERM_BENCHMARK=1`) keep the bundled icon, so that no
    /// helper process runs inside a measurement.
    static var isSupported: Bool {
        systemDrawsGlassIcons && !Preferences.isTestRun && ProcessInfo.processInfo.environment["MACTERM_BENCHMARK"] != "1"
    }

    /// macOS 26 and later. Settings shows the setting only there.
    static var systemDrawsGlassIcons: Bool {
        if #available(macOS 26, *) { true } else { false }
    }
}
