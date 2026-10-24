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
        /// The screen behind the characters. The icon's background is flat,
        /// so both ends are the same color.
        var backgroundTop: Color
        var backgroundBottom: Color
        /// Bottom to top, one for each group: the characters, the glass pane,
        /// the dark ring, and the silver frame. Nil keeps the group's bundled
        /// fills.
        var layers: [Color?]
        /// The layers with a color of their own: the cross and its shade.
        var accents: [AdaptiveIconRequest.Accent]
    }

    /// Where the cross is: the glass pane's group (the second from the bottom),
    /// and the first of its layers in IconRendering's order, which is the
    /// reverse of `layers` in `icon.json`.
    static let crossGroup = 1
    static let crossElement = 0
    /// The cross is the theme's white, palette 7: it follows the theme, and
    /// it stays light, as the silver frame is.
    static let crossEntry = 7
    /// The characters' group (the bottom one), and the palette entry the
    /// characters take: blue, one color over the whole screen.
    static let charactersGroup = 0
    /// The screen's gradient: the bottom layer of the characters' group. Over
    /// the background, which is the theme's background color, it lays the lid
    /// at the top of the screen and fades it out toward the bottom, along the
    /// cross's turn.
    static let screenGradientElement = 0
    /// The cross's shade: the top layer of the characters' group, black in
    /// every theme, as a shadow is.
    static let crossShadeElement = 2
    static let crossShade = Color(red: 0, green: 0, blue: 0)
    static let characterBase = 4

    /// The gray entries (bright white, white, bright black, black), in the
    /// order that breaks a tie.
    static let neutralEntries = [15, 7, 8, 0]
    /// The smallest step the lid's gray keeps from the background. Rose
    /// Pine's palette 0 is only 9% of the way to its frame gray, and it is
    /// still the gray its lid comes from. Gruvbox's palette 0 is the
    /// background itself, so its lid comes from the next gray.
    static let lidMinimumStep = 0.05
    /// The icon's colors. The frames keep their bundled fills in every theme:
    /// Ghostty's gradients, from `AppIcon.icon`. The cross is the theme's
    /// white (`crossEntry`).
    /// The characters are the theme's blue (`characterBase`). The screen is a
    /// gradient from the theme's lid at the top to its background at the
    /// bottom (`screenGradientElement`).
    ///
    /// The lid is the theme's next gray past the background: the nearest gray
    /// (palette 15, 7, 8 or 0) that is at least `lidMinimumStep` from the
    /// background toward the gray that stands out most, itself, with no mix.
    /// Distances are OKLab lightness away from the background, signed by the
    /// side of the gray that stands out most, so a light theme gets a lid
    /// darker than its background. That gray is palette 0 in most dark
    /// themes. In Gruvbox, whose palette 0 is the background, it is palette 8.
    ///
    /// In eyesclosed, the theme the icon was drawn in, this picks its
    /// background and its palette 0 for the screen, and its blue for the
    /// characters: the bundled icon's own fills. Nil when the
    /// theme has no gray that differs from the background.
    static func paint(for theme: ThemeColors) -> Paint? {
        guard theme.palette.count >= 16 else { return nil }
        let background = lightness(theme.background)
        let offset = theme.palette.prefix(16).map { lightness($0) - background }
        guard let front = first(of: neutralEntries, by: { -abs(offset[$0]) }), abs(offset[front]) > 0.01 else { return nil }
        let share = offset.map { $0 / offset[front] }
        // `front` itself qualifies, so a lid gray always exists.
        let lidGray = first(of: neutralEntries.filter { share[$0] >= lidMinimumStep }, by: { share[$0] }) ?? front
        let lid = theme.palette[lidGray]
        return Paint(
            backgroundTop: theme.background,
            backgroundBottom: theme.background,
            // The glass pane is the lid, so that only its glass shows.
            layers: [theme.palette[characterBase], lid, nil, nil],
            accents: [
                .init(group: crossGroup, element: crossElement, color: theme.palette[crossEntry]),
                .init(group: charactersGroup, element: screenGradientElement, color: lid),
                .init(group: charactersGroup, element: crossShadeElement, color: crossShade),
            ]
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
