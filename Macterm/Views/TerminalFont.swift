import AppKit
import SwiftUI

/// The font of the monospaced text in Macterm's own UI: the family of the
/// user's ghostty `font-family` (`TerminalFontFamily`), or the system
/// monospaced font when there is none.
///
/// This is the one place that views read. Use `Font.terminal` in SwiftUI and
/// `TerminalFont.shared.nsFont` in AppKit. Never use `.monospaced()`,
/// `design: .monospaced` or `NSFont.monospacedSystemFont` for text in the UI.
/// Each site keeps its own size and weight. Only the family changes.
///
/// `GhosttyApp.loadConfig` sets the family at each config load and reload.
/// The store is observable, so a view that drew a `Font.terminal` draws
/// again when the family changes.
@MainActor @Observable
final class TerminalFont {
    static let shared = TerminalFont()

    /// The installed family to draw with. nil is the system monospaced font.
    private(set) var family: String?

    @ObservationIgnored
    private var cache: [CacheKey: NSFont] = [:]

    private struct CacheKey: Hashable {
        var size: CGFloat
        var weight: CGFloat
    }

    init(family: String? = nil) {
        self.family = family
    }

    func update(family: String?) {
        guard family != self.family else { return }
        self.family = family
        cache.removeAll()
    }

    /// The font at this size and weight. When the family has no face that
    /// loads, this is the system monospaced font.
    func nsFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard let family else { return .monospacedSystemFont(ofSize: size, weight: weight) }
        let key = CacheKey(size: size, weight: weight.rawValue)
        if let cached = cache[key] { return cached }
        let font = Self.font(family: family, size: size, weight: weight)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
        cache[key] = font
        return font
    }

    /// The face of `family` nearest to `weight`, or nil when the family does
    /// not load. CoreText picks the nearest weight that the family has, so a
    /// family with only regular and bold gives bold for semibold.
    nonisolated static func font(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        guard let matched = descriptor.matchingFontDescriptor(withMandatoryKeys: [.family]),
              let font = NSFont(descriptor: matched, size: size),
              font.familyName == family
        else { return nil }
        return font
    }
}

extension Font {
    /// The UI's monospaced font at a fixed point size. Replaces
    /// `.system(size:weight:design: .monospaced)`.
    @MainActor
    static func terminal(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let store = TerminalFont.shared
        guard store.family != nil else { return .system(size: size, weight: weight, design: .monospaced) }
        return Font(store.nsFont(size: size, weight: weight.appKitWeight))
    }

    /// The UI's monospaced font at the size of a text style. Replaces
    /// `.caption.monospaced()` and `.system(.caption, design: .monospaced)`.
    @MainActor
    static func terminal(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        let store = TerminalFont.shared
        guard store.family != nil else { return .system(style, design: .monospaced).weight(weight) }
        return Font(store.nsFont(size: style.appKitPointSize, weight: weight.appKitWeight))
    }
}

extension Font.Weight {
    /// The AppKit weight with the same name.
    var appKitWeight: NSFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}

extension Font.TextStyle {
    /// The point size that macOS gives this text style.
    var appKitPointSize: CGFloat {
        NSFont.preferredFont(forTextStyle: appKitStyle).pointSize
    }

    private var appKitStyle: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}
