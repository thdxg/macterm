import Foundation
@testable import Macterm
import Testing

struct AdaptiveIconTests {
    private typealias Color = AdaptiveIcon.Color

    private static func hex(_ value: Int) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    private static func theme(_ background: Int, _ palette: [Int]) -> AdaptiveIcon.ThemeColors {
        AdaptiveIcon.ThemeColors(background: hex(background), palette: palette.map(hex))
    }

    /// The theme the icon is drawn in, and the default theme.
    private static let eyesclosed = theme(0x111214, [
        0x383B4A, 0xFFABA2, 0x779BB0, 0xECD8AE, 0xB7C8CB, 0x9A9DAE, 0xD8D0D0, 0xBBBCC7,
        0x696D7D, 0xFFABA2, 0x779BB0, 0xECD8AE, 0xB7C8CB, 0x9A9DAE, 0xD8D0D0, 0xCDCFD1,
    ])
    private static let rosePine = theme(0x191724, [
        0x26233A, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
        0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177, 0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
    ])
    /// Palette 0 is the background itself.
    private static let gruvboxDark = theme(0x282828, [
        0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
        0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
    ])
    /// A light theme: the black entries stand out from a white background.
    private static let gitHubLight = theme(0xFFFFFF, [
        0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
        0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F,
    ])
    /// Palette 15 is dimmer than palette 7 and than every color entry.
    private static let catppuccinMocha = theme(0x1E1E2E, [
        0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF, 0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
        0x585B70, 0xF7AEC2, 0xC2ECBF, 0xFCD682, 0xAECCFC, 0xF398DA, 0xB1EAE1, 0xA6ADC8,
    ])
    /// Palette 0 is the background, and palettes 7 and 8 are about as light
    /// as palette 15: no gray stands apart from both ends.
    private static let noMiddleGray = theme(0x1C1C1C, [
        0x1C1C1C, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xDCDCDC,
        0xD0D0D0, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xE4E4E4,
    ])
    /// A mid-gray background. Palette 15 is the front pane, and every color
    /// entry but palette 3 is darker than the background: as far from it as
    /// a step toward the front, but on the other side.
    private static let midGray = midGrayTheme(palette3: 0xDCCC94)

    private static func midGrayTheme(palette3: Int) -> AdaptiveIcon.ThemeColors {
        theme(0x7A7A7A, [
            0x606060, 0x2A0000, 0x002A00, palette3, 0x00002A, 0x2A002A, 0x003030, 0xA0A0A0,
            0xB4B4B4, 0x200000, 0x002000, 0x202000, 0x000020, 0x200020, 0x002020, 0xFFFFFF,
        ])
    }

    /// The palette entries a paint took, bottom to top, as the first entry
    /// with that color. Only for "is it a palette entry": a theme can repeat a
    /// color (Rose Pine's palette 7 and 15), so compare with `colors` instead.
    private static func entries(_ paint: AdaptiveIcon.Paint?, of theme: AdaptiveIcon.ThemeColors) -> [Int] {
        (paint?.layers ?? []).map { layer in theme.palette.firstIndex(of: layer) ?? -1 }
    }

    /// The colors of these palette entries, to compare with a paint's layers.
    private static func colors(_ theme: AdaptiveIcon.ThemeColors, _ entries: [Int]) -> [Color] {
        entries.map { theme.palette[$0] }
    }

    /// The solid fill of each group of `AppIcon.icon/icon.json` in the repo
    /// (the source Xcode compiles), bottom to top — the order the request
    /// carries them in, which is the reverse of the file's `groups`.
    private static let iconLayerFills: [Color] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // App
            .deletingLastPathComponent() // MactermTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Macterm/AppIcon.icon/icon.json")
        let data = (try? Data(contentsOf: url)) ?? Data()
        let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let groups = document["groups"] as? [[String: Any]] ?? []
        return groups.reversed().compactMap { group in
            let layer = (group["layers"] as? [[String: Any]])?.first
            let solid = (layer?["fill"] as? [String: Any])?["solid"] as? String
            let parts = solid?.split(separator: ":").last?.split(separator: ",").compactMap { Double($0) } ?? []
            return parts.count >= 3 ? Color(red: parts[0], green: parts[1], blue: parts[2]) : nil
        }
    }()

    private static func close(_ a: Color, _ b: Color) -> Bool {
        abs(a.red - b.red) < 1.5 / 255 && abs(a.green - b.green) < 1.5 / 255 && abs(a.blue - b.blue) < 1.5 / 255
    }

    // MARK: - Paint

    /// The rule and the design agree: in the theme the icon is drawn in, the
    /// adaptive icon is the bundled icon. A redesign that changes a fill or
    /// the number of groups fails here until `paint(for:)` follows.
    @Test
    func eyesclosedPaintsTheBundledIconsOwnColors() throws {
        let paint = try #require(AdaptiveIcon.paint(for: Self.eyesclosed))
        let fills = Self.iconLayerFills
        #expect(fills.count == paint.layers.count, "AppIcon.icon has \(fills.count) groups")
        for (painted, bundled) in zip(paint.layers, fills) {
            #expect(Self.close(painted, bundled), "painted \(painted), bundled \(bundled)")
        }
        #expect(paint.layers == Self.colors(Self.eyesclosed, [8, 5, 15, 15]))
    }

    @Test
    func theBackgroundRunsFromALighterTopToTheThemeBackground() throws {
        let paint = try #require(AdaptiveIcon.paint(for: Self.eyesclosed))
        #expect(paint.backgroundBottom == Self.hex(0x111214))
        #expect(Self.close(paint.backgroundTop, Self.hex(0x1A1B20)))
    }

    /// Every pane is one palette entry as the theme has it, never a mix.
    @Test
    func eachPaneIsAPaletteEntry() {
        for theme in [Self.eyesclosed, Self.rosePine, Self.gruvboxDark, Self.gitHubLight, Self.catppuccinMocha, Self.midGray] {
            let taken = Self.entries(AdaptiveIcon.paint(for: theme), of: theme)
            #expect(taken.count == 4 && !taken.contains(-1), "\(taken)")
        }
    }

    @Test
    func theMiddlePaneIsTheColorNearestTheMiddleOfTheRamp() {
        #expect(AdaptiveIcon.paint(for: Self.rosePine)?.layers == Self.colors(Self.rosePine, [8, 1, 15, 15]))
        // Palette 0 is the background in Gruvbox, so the back pane is palette 8.
        #expect(AdaptiveIcon.paint(for: Self.gruvboxDark)?.layers == Self.colors(Self.gruvboxDark, [8, 14, 15, 15]))
    }

    /// The front pane is the gray that stands out most, which in a light
    /// theme is a black entry, and in Catppuccin Mocha is palette 7.
    @Test
    func theFrontPaneIsTheGrayThatStandsOutMost() {
        #expect(AdaptiveIcon.paint(for: Self.gitHubLight)?.layers == Self.colors(Self.gitHubLight, [15, 9, 0, 0]))
        #expect(AdaptiveIcon.paint(for: Self.catppuccinMocha)?.layers.last == Self.catppuccinMocha.palette[7])
    }

    /// The panes step down evenly enough: no pane is as light as its
    /// neighbor in front, and the back pane stands apart from the background.
    /// Distances are signed by the front pane's side of the background.
    @Test
    func thePanesStepDownTowardTheBackground() throws {
        for theme in [Self.eyesclosed, Self.rosePine, Self.gruvboxDark, Self.gitHubLight, Self.midGray] {
            let paint = try #require(AdaptiveIcon.paint(for: theme))
            let background = AdaptiveIcon.lightness(theme.background)
            let offset = paint.layers.map { AdaptiveIcon.lightness($0) - background }
            let distance = offset.map { $0 * (offset[2] < 0 ? -1 : 1) }
            let front = distance[2]
            #expect(distance[0] / front >= AdaptiveIcon.minimumStep, "back pane too close to the background")
            #expect((distance[1] - distance[0]) / front >= AdaptiveIcon.minimumStep, "back and middle too close")
            #expect((distance[2] - distance[1]) / front >= AdaptiveIcon.minimumStep, "middle and front too close")
        }
    }

    /// With no gray apart from the background there is no ramp, and no paint.
    @Test
    func aThemeWithNoContrastPaintsNothing() {
        let flat = AdaptiveIcon.ThemeColors(background: Self.hex(0x808080), palette: Array(repeating: Self.hex(0x808080), count: 16))
        #expect(AdaptiveIcon.paint(for: flat) == nil)
        #expect(AdaptiveIcon.paint(for: AdaptiveIcon.ThemeColors(background: Self.hex(0), palette: [])) == nil)
    }

    /// The gray nearest 45% is the background itself, so a back pane in it
    /// would not show. The bundled icon shows instead.
    @Test
    func aThemeWithNoGrayBetweenTheEndsPaintsNothing() {
        #expect(AdaptiveIcon.paint(for: Self.noMiddleGray) == nil)
    }

    /// On a mid-gray background a dark color entry is as far from the
    /// background as a light one. Only an entry on the front pane's side is
    /// a step toward it.
    @Test
    func theMiddlePaneIsOnTheFrontPanesSideOfTheBackground() {
        #expect(AdaptiveIcon.paint(for: Self.midGray)?.layers == Self.colors(Self.midGray, [8, 3, 15, 15]))
        // With palette 3 dark too, no color entry is on that side.
        #expect(AdaptiveIcon.paint(for: Self.midGrayTheme(palette3: 0x303000)) == nil)
    }

    @Test
    func lightnessRunsFromBlackToWhite() {
        #expect(abs(AdaptiveIcon.lightness(Self.hex(0x000000))) < 1e-6)
        #expect(abs(AdaptiveIcon.lightness(Self.hex(0xFFFFFF)) - 1) < 1e-3)
        #expect(AdaptiveIcon.lightness(Self.hex(0x696D7D)) < AdaptiveIcon.lightness(Self.hex(0x9A9DAE)))
    }

    @Test
    func mixIsLinearPerComponent() {
        let mixed = AdaptiveIcon.mix(Color(red: 1, green: 0.5, blue: 0), into: Color(red: 0, green: 0.5, blue: 1), amount: 0.25)
        #expect(mixed == Color(red: 0.25, green: 0.5, blue: 0.75))
    }

    // MARK: - Icon style

    @Test
    func theRegularStyleFollowsTheSystemOrItsOwnSide() {
        #expect(AdaptiveIcon.appearance(iconStyle: nil, systemScheme: .dark) == .dark)
        #expect(AdaptiveIcon.appearance(iconStyle: nil, systemScheme: .light) == .light)
        #expect(AdaptiveIcon.appearance(iconStyle: "Regular", systemScheme: .dark) == .dark)
        #expect(AdaptiveIcon.appearance(iconStyle: "RegularAutomatic", systemScheme: .light) == .light)
        #expect(AdaptiveIcon.appearance(iconStyle: "RegularDark", systemScheme: .light) == .dark)
        #expect(AdaptiveIcon.appearance(iconStyle: "RegularLight", systemScheme: .dark) == .light)
    }

    /// The system draws the bundled icon in these styles itself.
    @Test
    func clearTintedAndUnknownStylesStepAside() {
        for style in ["Clear", "ClearDark", "ClearAutomatic", "Tinted", "TintedLight", "TintedAutomatic", "Something New"] {
            #expect(AdaptiveIcon.appearance(iconStyle: style, systemScheme: .dark) == nil, "\(style)")
        }
    }

    // MARK: - Decision

    @Test
    func theAdaptiveIconNeedsTheSettingSupportAndTheBundledIcon() {
        func decide(
            enabled: Bool = true,
            supported: Bool = true,
            configured: GhosttyAppIcon = .bundled,
            style: String? = nil
        ) -> AdaptiveIcon.Decision {
            AdaptiveIcon.decide(
                enabled: enabled,
                supported: supported,
                configured: configured,
                iconStyle: style,
                systemScheme: { .dark }
            )
        }
        let custom = GhosttyAppIcon.custom(URL(fileURLWithPath: "/tmp/mine.png"))
        #expect(decide() == .adaptive(.dark))
        #expect(decide(enabled: false) == .configured(.bundled))
        #expect(decide(supported: false) == .configured(.bundled))
        #expect(decide(configured: custom) == .configured(custom))
        #expect(decide(style: "TintedDark") == .configured(.bundled))
    }

    /// The controller reads the system scheme from `GhosttyApp.shared`. With
    /// the adaptive icon off, `decide` must not ask for it, so that a test
    /// that flips the setting never starts libghostty.
    @Test
    func theSystemSchemeIsReadOnlyForAnAdaptiveIcon() {
        var reads = 0
        let scheme: () -> ThemeResolver.Scheme = {
            reads += 1
            return .dark
        }
        let custom = GhosttyAppIcon.custom(URL(fileURLWithPath: "/tmp/mine.png"))
        _ = AdaptiveIcon.decide(enabled: false, supported: true, configured: .bundled, iconStyle: nil, systemScheme: scheme)
        _ = AdaptiveIcon.decide(enabled: true, supported: false, configured: .bundled, iconStyle: nil, systemScheme: scheme)
        _ = AdaptiveIcon.decide(enabled: true, supported: true, configured: custom, iconStyle: nil, systemScheme: scheme)
        #expect(reads == 0)
        #expect(AdaptiveIcon
            .decide(enabled: true, supported: true, configured: .bundled, iconStyle: nil, systemScheme: scheme) == .adaptive(.dark))
        #expect(reads == 1)
    }

    /// Tests never start the helper on their own.
    @Test
    func runsAreNotSupported() {
        #expect(!AdaptiveIcon.isSupported)
    }
}
