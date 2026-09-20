import Foundation

/// The user's ghostty `mouse-scroll-multiplier`, read from their raw config
/// text.
///
/// Raw text rather than `ghostty_config_get` for the reason
/// `GhosttyColorSpace` gives: the key is a Zig struct with no C shape in
/// `ghostty.h`, so the getter has nothing to write into.
///
/// Macterm needs the number only to speak libghostty's own scroll language
/// back to it: a scroller drag is translated into the precision-scroll
/// deltas the core already accumulates (`ScrollAccumulator`), and the core
/// scales every one of them by `precision` on the way in. Nothing else here
/// reads it — a wheel event is forwarded untouched and the multiplier
/// applies inside ghostty exactly as it does in Ghostty.app (#393).
struct MouseScrollMultiplier: Equatable {
    static let key = "mouse-scroll-multiplier"

    /// ghostty's own defaults (`Config.MouseScrollMultiplier`).
    var precision: Double = 1
    var discrete: Double = 3

    static let `default` = MouseScrollMultiplier()

    /// Parses ghostty's two accepted forms: a bare number, which sets both,
    /// or `precision:X,discrete:Y` with either field present. An
    /// unparseable value falls back to the default the way ghostty's parser
    /// rejects it, and an unknown field is ignored rather than fatal.
    static func parse(_ value: String?) -> MouseScrollMultiplier {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
            return .default
        }
        if let bare = Double(value) { return MouseScrollMultiplier(precision: bare, discrete: bare) }

        var result = MouseScrollMultiplier.default
        var sawField = false
        for field in value.split(separator: ",") {
            let parts = field.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let number = Double(parts[1].trimmingCharacters(in: .whitespaces))
            else { continue }
            switch parts[0].trimmingCharacters(in: .whitespaces).lowercased() {
            case "precision": result.precision = number
                sawField = true
            case "discrete": result.discrete = number
                sawField = true
            default: continue
            }
        }
        return sawField ? result : .default
    }

    static func resolve(userConfigText: String?) -> MouseScrollMultiplier {
        guard let text = userConfigText else { return .default }
        return parse(GhosttyConfigText.lastValue(of: key, inConfigText: text))
    }
}
