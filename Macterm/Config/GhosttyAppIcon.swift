import Foundation

/// The app icon the user's ghostty config asks for — Ghostty's `macos-icon`
/// and `macos-custom-icon` keys, read with the same semantics Ghostty.app
/// gives them (`macos/Sources/Features/Custom App Icon/AppIcon.swift`).
///
/// Only `macos-icon = custom` has a Macterm meaning: the image at
/// `macos-custom-icon` replaces the Dock and app-switcher icon. Every other
/// value — `official`, the artist variants (`blueprint`, `xray`, …) and
/// `custom-style` with its `macos-icon-ghost-color` / `-screen-color` /
/// `-frame` companions — names Ghostty-brand artwork Macterm doesn't ship,
/// so it resolves to the bundled icon. Pure: the decision is made from the
/// two values alone; whether the file exists and decodes is the applier's
/// business (`AppIconPresenter`), because that is where the fallback and its
/// log line live.
enum GhosttyAppIcon: Equatable {
    /// The bundle's own icon — the default, and the fallback for everything
    /// Macterm can't honor.
    case bundled
    /// `macos-icon = custom`: the image file to install. Always an absolute
    /// file URL; the file is not yet known to exist.
    case custom(URL)

    static let styleKey = "macos-icon"
    static let customPathKey = "macos-custom-icon"
    /// `macos-icon` values, spelled as ghostty's `MacAppIcon` tags. Named for
    /// the key rather than shortened, because ghostty *also* has a value
    /// literally called `custom-style` (the colorized ghost) and a constant
    /// called `customStyle` holding `"custom"` reads as that one.
    static let macosIconOfficial = "official"
    static let macosIconCustom = "custom"
    /// Ghostty's default for `macos-custom-icon` when `custom` is chosen and no
    /// path is given (`Ghostty.Config.macosCustomIcon`).
    static let defaultCustomPath = "~/.config/ghostty/Ghostty.icns"

    /// - Parameters:
    ///   - style: the effective `macos-icon` value (nil when the getter fails).
    ///   - customPath: the effective `macos-custom-icon` value, nil when unset.
    ///   - expandTilde: `~` expansion, injected so tests can pin a home. The
    ///     default is the same call Ghostty.app makes.
    ///
    /// A path that is still relative after expansion is invalid: Ghostty
    /// resolves one against the process's working directory, which for a GUI
    /// app is nothing a user can predict, so Macterm falls back instead.
    static func resolve(
        style: String?,
        customPath: String?,
        expandTilde: (String) -> String = { ($0 as NSString).expandingTildeInPath }
    ) -> GhosttyAppIcon {
        guard isCustom(style: style) else { return .bundled }
        let stated = customPath?.trimmingCharacters(in: .whitespaces) ?? ""
        let expanded = expandTilde(stated.isEmpty ? defaultCustomPath : stated)
        guard expanded.hasPrefix("/") else { return .bundled }
        return .custom(URL(fileURLWithPath: expanded))
    }

    /// Whether the user asked for `macos-icon = custom`, i.e. whether
    /// `macos-custom-icon` is consulted at all. The one place the trimming
    /// rule lives, so `resolve` and its caller's log lines can't disagree
    /// about what counts as `custom`.
    static func isCustom(style: String?) -> Bool {
        style?.trimmingCharacters(in: .whitespaces) == macosIconCustom
    }

    /// Whether `style` names Ghostty artwork Macterm has no equivalent for —
    /// the one fallback worth a log line, since the user asked for something.
    static func isGhosttyArtwork(style: String?) -> Bool {
        guard let style = style?.trimmingCharacters(in: .whitespaces), !style.isEmpty else { return false }
        return style != macosIconOfficial && style != macosIconCustom
    }
}
