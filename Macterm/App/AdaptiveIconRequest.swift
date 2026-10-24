import Foundation

/// What the app asks `macterm-icon-renderer` to draw: the app icon from the
/// bundle's compiled asset catalog, with its fills replaced by theme colors.
///
/// The wire contract between the app (`AdaptiveIconRenderer`) and the helper
/// (`IconRenderer/main.swift`). Compiled into both targets, as
/// `ControlProtocol` is into the app and the CLI, so the two can never read
/// different shapes. The request is JSON in the helper's only argument; the
/// answer is a PNG on its stdout, or an `AdaptiveIconRenderExit` code.
struct AdaptiveIconRequest: Codable, Equatable, Hashable {
    /// Which of the catalog's two icon stacks to draw: the light one or the
    /// dark one. The dark stack keeps its own chiclet; drawing the light
    /// stack in the dark style swaps the background for the system's dark one.
    enum Appearance: String, Codable {
        case light
        case dark
    }

    /// One layer's fill: `element` counts the layers of group `group` in
    /// the order IconRendering keeps them, as `group` counts `layers`.
    struct Accent: Codable, Equatable, Hashable {
        var group: Int
        var element: Int
        var color: Color
    }

    /// An sRGB color, each component 0…1.
    struct Color: Codable, Equatable, Hashable {
        var red: Double
        var green: Double
        var blue: Double
    }

    /// Absolute path of the compiled asset catalog (`Contents/Resources/Assets.car`).
    var catalogPath: String
    /// The icon's name in the catalog — `ASSETCATALOG_COMPILER_APPICON_NAME`.
    var iconName: String
    var appearance: Appearance
    /// The background's gradient, top to bottom.
    var backgroundTop: Color
    var backgroundBottom: Color
    /// One fill for each layer group of the icon, **bottom to top** — the
    /// order IconRendering keeps them in, which is the reverse of the
    /// `groups` array in `AppIcon.icon/icon.json`. The helper refuses a
    /// request whose count differs from the icon's, so an icon redesign that
    /// adds or removes a group falls back to the bundled icon instead of
    /// painting the wrong layers.
    var layers: [Color]
    /// Fills for single layers inside a group, applied after `layers`: a
    /// layer that keeps a color of its own in every theme, such as the
    /// blush in the characters. Nil when every layer takes its group's fill.
    var accents: [Accent]?
    /// Edge length of the square PNG, in pixels.
    var pixels: Int
}

/// How `macterm-icon-renderer` ends. Anything but `ok` — and any signal —
/// means the app keeps the bundled icon.
enum AdaptiveIconRenderExit: Int32 {
    case ok = 0
    /// The argument was not an `AdaptiveIconRequest`.
    case badRequest = 2
    /// CoreUI could not open the asset catalog.
    case catalogUnreadable = 3
    /// The catalog has no icon stack with that name and appearance.
    case iconMissing = 4
    /// The icon's layer groups no longer match the request.
    case structureChanged = 5
    /// IconRendering returned no image, or the PNG could not be written.
    case renderFailed = 6
    /// This macOS lacks a private symbol that the helper calls
    /// (`RequiredSymbols`). stderr names each one.
    case apiMissing = 7
}
