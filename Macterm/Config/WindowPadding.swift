import Foundation

/// The user's ghostty `window-padding-x`, read from their raw config text.
///
/// Raw text rather than `ghostty_config_get`, as for `MouseScrollMultiplier`:
/// the key is a Zig struct (left and right) with no C shape in `ghostty.h`.
///
/// Macterm needs the left padding to turn libghostty's IME point into a
/// cursor column (`GhosttyTerminalNSView.cursorColumn`): the point is the
/// middle of the cursor's cell, measured from the view's edge, so the
/// padding is in it. `window-padding-balance` adds at most half a cell more
/// on the left, which a round down absorbs.
struct WindowPadding: Equatable {
    static let key = "window-padding-x"

    /// Points. ghostty's own default.
    var left: Double = 2

    static let `default` = WindowPadding()

    /// Parses ghostty's two forms: one number for both sides, or
    /// `left,right`. An unparseable value is the default, as ghostty's
    /// parser rejects it.
    static func parse(_ value: String?) -> WindowPadding {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return .default }
        let first = value.split(separator: ",", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first, let left = Double(first), left >= 0 else { return .default }
        return WindowPadding(left: left)
    }

    static func resolve(userConfigText: String?) -> WindowPadding {
        guard let text = userConfigText else { return .default }
        return parse(GhosttyConfigText.lastValue(of: key, inConfigText: text))
    }
}
