import AppKit

/// The user's ghostty `font-family`, read from their raw config text, for the
/// monospaced text that Macterm's own UI draws (commands, paths, logs and
/// keybinds in panels, sheets and Settings). The UI then reads as one surface
/// with the terminal. `TerminalFont` holds the result for the views.
///
/// Raw text rather than `ghostty_config_get`: the key is a
/// `RepeatableString`, which has no C shape in `ghostty.h`. As for every raw
/// read, a value in a `config-file` include is not seen.
///
/// There is no Settings UI. The ghostty key is the setting.
enum TerminalFontFamily {
    static let key = "font-family"

    /// The families that the config lists, in order, as ghostty builds the
    /// list: each line appends a family, and an empty value clears the list.
    static func families(inConfigText text: String) -> [String] {
        var result: [String] = []
        for value in GhosttyConfigText.values(of: key, inConfigText: text) {
            if value.isEmpty {
                result.removeAll()
            } else {
                result.append(value)
            }
        }
        return result
    }

    /// The first listed family that `familyOfFont` can load, as its canonical
    /// family name. nil means "use the system monospaced font": no config,
    /// no family, or no listed family that is installed. ghostty also uses
    /// the next family in the list when one is missing.
    ///
    /// `familyOfFont` turns a configured name (a family, a PostScript name or
    /// a full name, in any case) into the installed font's family name, or
    /// nil when no font has that name.
    static func resolve(
        userConfigText: String?,
        familyOfFont: (String) -> String? = Self.installedFamily(named:)
    ) -> String? {
        guard let text = userConfigText else { return nil }
        for family in families(inConfigText: text) {
            if let installed = familyOfFont(family), !installed.isEmpty { return installed }
        }
        return nil
    }

    /// The family of the installed font with this name, or nil.
    /// `NSFont(name:size:)` returns nil for a name that no font has; it
    /// never falls back to another font.
    static func installedFamily(named name: String) -> String? {
        NSFont(name: name, size: NSFont.systemFontSize)?.familyName
    }
}
