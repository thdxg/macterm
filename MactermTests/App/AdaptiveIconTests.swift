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
    /// A mid-gray background. Palette 15 is the frame, and palette 0 is
    /// darker than the background: on the other side of it from the frame.
    private static let midGray = midGrayTheme(palette3: 0xDCCC94)

    private static func midGrayTheme(palette3: Int) -> AdaptiveIcon.ThemeColors {
        theme(0x7A7A7A, [
            0x606060, 0x2A0000, 0x002A00, palette3, 0x00002A, 0x2A002A, 0x003030, 0xA0A0A0,
            0xB4B4B4, 0x200000, 0x002000, 0x202000, 0x000020, 0x200020, 0x002020, 0xFFFFFF,
        ])
    }

    /// The bundled icon, as `AppIcon.icon/icon.json` in the repo (the source
    /// Xcode compiles) declares it: the background fill, and the solid fill of
    /// each layer that draws, in IconRendering's order: groups bottom to top,
    /// the reverse of the file's `groups`, and in each group its layers in the
    /// reverse of the file's `layers`. A group with no visible layer drops out
    /// of the compiled icon, so it drops out here too.
    private static let bundled: (background: Color?, groups: [[Color?]]) = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // App
            .deletingLastPathComponent() // MactermTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Macterm/AppIcon.icon/icon.json")
        let data = (try? Data(contentsOf: url)) ?? Data()
        let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        func color(_ fill: Any?) -> Color? {
            let solid = (fill as? [String: Any])?["solid"] as? String
            let parts = solid?.split(separator: ":").last?.split(separator: ",").compactMap { Double($0) } ?? []
            return parts.count >= 3 ? Color(red: parts[0], green: parts[1], blue: parts[2]) : nil
        }
        let groups: [[Color?]] = (document["groups"] as? [[String: Any]] ?? []).reversed().compactMap { group in
            let layers = (group["layers"] as? [[String: Any]] ?? []).filter { $0["hidden"] as? Bool != true }
            guard group["hidden"] as? Bool != true, !layers.isEmpty else { return nil }
            return layers.reversed().map { color($0["fill"]) }
        }
        return (color(document["fill"]), groups)
    }()

    private static func close(_ a: Color, _ b: Color) -> Bool {
        abs(a.red - b.red) < 1.5 / 255 && abs(a.green - b.green) < 1.5 / 255 && abs(a.blue - b.blue) < 1.5 / 255
    }

    // MARK: - Paint

    /// The rule and the design agree: in the theme the icon is drawn in, the
    /// adaptive icon is the bundled icon, layer by layer. A layer takes its
    /// accent's color, or else its group's. A redesign that changes a fill,
    /// a layer or the number of groups fails here until `paint(for:)` follows.
    @Test
    func eyesclosedPaintsTheBundledIconsOwnColors() throws {
        let paint = try #require(AdaptiveIcon.paint(for: Self.eyesclosed))
        let groups = Self.bundled.groups
        #expect(groups.count == paint.layers.count, "AppIcon.icon draws \(groups.count) groups")
        for (group, fills) in groups.enumerated() where group < paint.layers.count {
            for (element, fill) in fills.enumerated() {
                let accent = paint.accents.first { $0.group == group && $0.element == element }
                let painted = accent?.color ?? paint.layers[group]
                let bundled = try #require(fill, "layer \(element) of group \(group) has no solid fill")
                #expect(Self.close(painted, bundled), "group \(group), layer \(element): painted \(painted), bundled \(bundled)")
            }
        }
        for accent in paint.accents {
            #expect(
                groups.indices.contains(accent.group) && groups[accent.group].indices.contains(accent.element),
                "no layer for \(accent)"
            )
        }
        let background = try #require(Self.bundled.background)
        #expect(Self.close(paint.backgroundTop, background), "painted \(paint.backgroundTop), bundled \(background)")
        // eyesclosed's lid.
        #expect(Self.close(paint.backgroundTop, Self.hex(0x1A1B21)))
    }

    /// The cross is the most colorful of palette 1 to 6. Red wins in most
    /// themes, also in muted eyesclosed. GitHub Light's magenta is a little
    /// more colorful than its red.
    @Test
    func theCrossIsTheMostColorfulANSIColor() throws {
        let expected = [
            (Self.eyesclosed, 1), (Self.rosePine, 1), (Self.gruvboxDark, 1), (Self.gitHubLight, 5), (Self.catppuccinMocha, 1),
        ]
        for (theme, entry) in expected {
            let paint = try #require(AdaptiveIcon.paint(for: theme))
            let cross = try #require(paint.accents.first { $0.group == AdaptiveIcon.crossGroup && $0.element == AdaptiveIcon.crossElement })
            #expect(cross.color == theme.palette[entry])
        }
    }

    /// Chroma is 0 for a gray and grows with color.
    @Test
    func chromaIsZeroForAGray() {
        #expect(AdaptiveIcon.chroma(Self.hex(0x808080)) < 1e-6)
        #expect(AdaptiveIcon.chroma(Self.hex(0xFF0000)) > AdaptiveIcon.chroma(Self.hex(0xFFABA2)))
    }

    /// The frames keep the bundled colors in every theme, a light one too.
    @Test
    func theFramesKeepTheBundledColors() throws {
        for theme in [Self.eyesclosed, Self.rosePine, Self.gruvboxDark, Self.gitHubLight, Self.catppuccinMocha, Self.midGray] {
            let paint = try #require(AdaptiveIcon.paint(for: theme))
            #expect(paint.layers[2] == AdaptiveIcon.darkRing)
            #expect(paint.layers[3] == AdaptiveIcon.silverFrame)
        }
    }

    /// The screen is the lid: palette 0 mixed into the background in
    /// eyesclosed, Rose Pine and Catppuccin Mocha. It is flat.
    @Test
    func theScreenIsPalette0MixedIntoTheBackground() throws {
        for theme in [Self.eyesclosed, Self.rosePine, Self.catppuccinMocha] {
            let paint = try #require(AdaptiveIcon.paint(for: theme))
            #expect(paint.backgroundTop == AdaptiveIcon.mix(theme.palette[0], into: theme.background, amount: AdaptiveIcon.lidMix))
            #expect(paint.backgroundBottom == paint.backgroundTop)
            // The glass pane over the characters has the screen's color.
            #expect(paint.layers[1] == paint.backgroundTop)
        }
    }

    /// Gruvbox's palette 0 is its background, so its lid comes from palette
    /// 8, near Gruvbox's own bg1 (#3C3836).
    @Test
    func aPalette0AtTheBackgroundTakesTheNextGray() throws {
        let paint = try #require(AdaptiveIcon.paint(for: Self.gruvboxDark))
        #expect(paint.backgroundTop == AdaptiveIcon.mix(
            Self.gruvboxDark.palette[8],
            into: Self.gruvboxDark.background,
            amount: AdaptiveIcon.lidMix
        ))
    }

    /// The lid steps toward the side of the gray that stands out most: darker
    /// than GitHub Light's white, and lighter than the mid-gray background,
    /// whose palette 0 is on the other side.
    @Test
    func theLidStepsTowardTheFrontGray() throws {
        let light = try #require(AdaptiveIcon.paint(for: Self.gitHubLight))
        #expect(AdaptiveIcon.lightness(light.backgroundTop) < AdaptiveIcon.lightness(Self.gitHubLight.background))
        let mid = try #require(AdaptiveIcon.paint(for: Self.midGray))
        #expect(AdaptiveIcon.lightness(mid.backgroundTop) > AdaptiveIcon.lightness(Self.midGray.background))
    }

    /// The characters are a mesh of the theme's ANSI colors: blue over all,
    /// and red, yellow, magenta, green and cyan toward their corners.
    @Test
    func theCharactersAreAMeshOfTheANSIColors() throws {
        for theme in [Self.eyesclosed, Self.rosePine, Self.gruvboxDark, Self.gitHubLight, Self.catppuccinMocha, Self.midGray] {
            let paint = try #require(AdaptiveIcon.paint(for: theme))
            #expect(paint.layers[AdaptiveIcon.charactersGroup] == theme.palette[4])
            let mesh = paint.accents.filter { $0.group == AdaptiveIcon.charactersGroup }
            #expect(mesh.map(\.element) == [1, 2, 3, 4, 5])
            #expect(mesh.map(\.color) == [1, 3, 5, 2, 6].map { theme.palette[$0] })
        }
    }

    /// With no gray apart from the background there is no ramp, and no paint.
    @Test
    func aThemeWithNoContrastPaintsNothing() {
        let flat = AdaptiveIcon.ThemeColors(background: Self.hex(0x808080), palette: Array(repeating: Self.hex(0x808080), count: 16))
        #expect(AdaptiveIcon.paint(for: flat) == nil)
        #expect(AdaptiveIcon
            .paint(for: AdaptiveIcon.ThemeColors(background: Self.hex(0), palette: [])) == nil)
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
