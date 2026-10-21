import Foundation

/// The languages of Macterm's own text, for Settings → General → Language
/// (`Preferences.appLanguage`).
enum AppLanguage {
    /// The languages that the bundle has a translation for, English first,
    /// then by code. `Base` is not a language.
    static var available: [String] {
        order(Bundle.main.localizations)
    }

    static func order(_ localizations: [String]) -> [String] {
        localizations
            .filter { $0 != "Base" }
            .sorted { ($0 == "en" ? 0 : 1, $0) < ($1 == "en" ? 0 : 1, $1) }
    }

    /// The name of a language in that language: "English", "한국어". A user
    /// who cannot read the current language can still find their own.
    static func nativeName(of code: String) -> String {
        let locale = Locale(identifier: code)
        guard let name = locale.localizedString(forIdentifier: code) else { return code }
        return name.capitalized(with: locale)
    }

    /// The language of `available` that a stored preference means, or nil
    /// for none. System Settings can store a region with the language
    /// (`ko-KR`); Macterm stores the code of the translation (`ko`).
    static func match(_ stored: String?, in available: [String]) -> String? {
        guard let stored, !stored.isEmpty else { return nil }
        if available.contains(stored) { return stored }
        let wanted = Locale(identifier: stored).language
        return available.first { code in
            let language = Locale(identifier: code).language
            guard language.languageCode == wanted.languageCode else { return false }
            // zh-Hans and zh-Hant share a language code: a script that
            // the translation names must agree too.
            return language.script == nil || language.script == wanted.script
        }
    }
}
