import AppKit

/// The color space ghostty renders a surface in — the user's
/// `window-colorspace`.
///
/// Read from their raw config text rather than asked of libghostty, for the
/// same reason `ShellIntegrationFeatures` does: `ghostty_config_get` returns
/// nothing for this enum (measured — it hands back an empty string), and the
/// surface layer is an `IOSurfaceLayer`, not a `CAMetalLayer`, so there is no
/// `colorspace` property to read either. Its only attached hint is an
/// undocumented numeric code.
///
/// It matters because sampled pixels and OSC 11 colors are numbers *in this
/// space*. Read as sRGB while ghostty paints Display P3, the chrome tint lands
/// about (-2, +0.5, -2) off the pane it is meant to match — visible as a seam
/// where the pane's own paint meets the padding.
enum GhosttyColorSpace {
    static let key = "window-colorspace"

    /// ghostty's default is sRGB, so an unset (or unrecognized) value means
    /// sRGB rather than "unknown".
    static func resolve(userConfigText: String?) -> NSColorSpace {
        guard let text = userConfigText,
              let value = GhosttyConfigText.lastValue(of: key, inConfigText: text)
        else { return .sRGB }
        return switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "display-p3": .displayP3
        default: .sRGB
        }
    }
}
