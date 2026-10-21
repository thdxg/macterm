import Foundation
@testable import Macterm
import Testing

struct AppLanguageTests {
    @Test
    func the_list_has_each_translation_with_english_first_and_no_base() {
        #expect(AppLanguage.order(["ko", "Base", "zh-Hans", "en"]) == ["en", "ko", "zh-Hans"])
        #expect(AppLanguage.available.first == "en")
        #expect(AppLanguage.available.contains("ko"))
        #expect(!AppLanguage.available.contains("Base"))
    }

    @Test
    func each_language_has_its_own_name() {
        #expect(AppLanguage.nativeName(of: "en") == "English")
        #expect(AppLanguage.nativeName(of: "ko") == "한국어")
    }

    /// System Settings stores a region with the language; Macterm stores the
    /// code of the translation. Both mean the same choice.
    @Test
    func a_stored_language_matches_its_translation() {
        let available = ["en", "ko", "zh-Hans"]
        #expect(AppLanguage.match("ko", in: available) == "ko")
        #expect(AppLanguage.match("ko-KR", in: available) == "ko")
        #expect(AppLanguage.match("en-US", in: available) == "en")
        #expect(AppLanguage.match("zh-Hans-CN", in: available) == "zh-Hans")
        #expect(AppLanguage.match("zh-Hant-TW", in: available) == nil, "another script is another translation")
        #expect(AppLanguage.match("fr", in: available) == nil)
        #expect(AppLanguage.match(nil, in: available) == nil)
    }

    /// The choice is Foundation's `AppleLanguages` key, which System Settings
    /// writes too. System removes the key, so macOS decides.
    @MainActor
    @Test
    func the_choice_is_the_apple_languages_key() {
        let preferences = Preferences.shared
        let saved = preferences.appLanguage
        defer { preferences.appLanguage = saved }

        /// The persistent domain, not `stringArray(forKey:)`: the test scheme
        /// passes `-AppleLanguages (en)`, and the argument domain wins a read.
        func stored() -> [String]? {
            Preferences.defaults.persistentDomain(forName: appBundleID + ".tests")?["AppleLanguages"] as? [String]
        }
        preferences.appLanguage = "ko"
        #expect(stored() == ["ko"])
        preferences.appLanguage = nil
        #expect(stored() == nil)
    }
}
