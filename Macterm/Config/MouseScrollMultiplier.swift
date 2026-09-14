import Foundation

/// The user's ghostty `mouse-scroll-multiplier`, applied to Macterm's own
/// scrollback wheel handling (`SurfaceScrollView`) so one key governs
/// scrolling on both paths: libghostty applies it itself inside vim, less and
/// any mouse-reporting program, and Macterm applies it to the primary-screen
/// scrollback it drives through `scroll_to_row`.
///
/// Read from the raw config text, not `ghostty_config_get`: the key is a Zig
/// struct with no C representation (`src/config/c_get.zig` returns false for
/// it), the same reason `ShellIntegrationFeatures` and `GhosttyColorSpace`
/// scan the text. A value set inside a recursively loaded `config-file`
/// include is therefore not seen.
///
/// The grammar is ghostty's (`Config.MouseScrollMultiplier.parseCLI`): a bare
/// number sets both device classes; `precision:X,discrete:Y` sets either or
/// both, in any order, and a field left out keeps the value it already had —
/// which, since ghostty processes lines in order, is the previous line's or
/// the default. An unparseable line is dropped and the previous value kept,
/// as ghostty does when it logs a config error.
struct MouseScrollMultiplier: Equatable {
    /// Trackpads and Magic Mice — events with `hasPreciseScrollingDeltas`.
    var precision: Double
    /// Mouse wheels — one wheel notch per event.
    var discrete: Double

    static let key = "mouse-scroll-multiplier"

    /// Ghostty's own range for the value (its reference says both extremes
    /// are "problematic"); out-of-range numbers are clamped rather than
    /// rejected, matching a value ghostty would accept.
    static let range: ClosedRange<Double> = 0.01 ... 10000

    /// What Macterm ships in `macterm-defaults.conf`. Ghostty's default is
    /// `precision:1,discrete:3`; Macterm's scrollback has always moved one row
    /// per wheel notch, so the discrete side is pinned to 1 there and this is
    /// the value an unset key resolves to. Kept in one place so the pin and
    /// the fallback can't drift apart (`MactermConfigTests` asserts the pin).
    static let mactermDefault = MouseScrollMultiplier(precision: 1, discrete: 1)

    /// The multiplier for one scroll event, chosen the way ghostty does: by
    /// whether the event carries precise deltas.
    func value(precise: Bool) -> Double {
        precise ? precision : discrete
    }

    /// Fold every `mouse-scroll-multiplier` line in the user's config text
    /// onto the Macterm default, last line winning and an empty value
    /// resetting to the default — libghostty's semantics for the key.
    static func resolve(userConfigText: String?) -> MouseScrollMultiplier {
        guard let text = userConfigText else { return mactermDefault }
        var current = mactermDefault
        for raw in GhosttyConfigText.values(of: key, inConfigText: text) {
            if raw.isEmpty {
                current = mactermDefault
            } else if let parsed = parse(raw, onto: current) {
                current = parsed
            }
        }
        return current
    }

    /// One value as ghostty parses it, or nil for a line ghostty would
    /// reject. `previous` supplies the field a `precision:`/`discrete:` form
    /// leaves out.
    static func parse(_ raw: String, onto previous: MouseScrollMultiplier) -> MouseScrollMultiplier? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        if let bare = number(value) {
            return MouseScrollMultiplier(precision: bare, discrete: bare)
        }
        var result = previous
        for field in value.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = field.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let amount = number(String(parts[1]))
            else { return nil }
            switch parts[0].trimmingCharacters(in: .whitespaces) {
            case "precision": result.precision = amount
            case "discrete": result.discrete = amount
            default: return nil
            }
        }
        return result
    }

    private static func number(_ text: String) -> Double? {
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)), v.isFinite else { return nil }
        return min(max(v, range.lowerBound), range.upperBound)
    }
}
