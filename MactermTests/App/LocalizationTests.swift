import Foundation
@testable import Macterm
import Testing

/// Holds the String Catalogs to what the app needs from them.
///
/// The catalogs are read from the repository, not from the bundle: the build
/// compiles away the states and the source language, and those are what the
/// tests check. `mise run strings --check` (CI) makes sure that the catalog
/// has exactly the strings of the code. These tests make sure that each of
/// those strings has a usable translation in every language of the catalog.
struct LocalizationTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // App
        .deletingLastPathComponent() // MactermTests
        .deletingLastPathComponent() // repo root

    private struct Catalog {
        let sourceLanguage: String
        let strings: [String: [String: Any]]

        init(_ name: String) throws {
            let url = LocalizationTests.root.appendingPathComponent("Macterm/\(name).xcstrings")
            let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            sourceLanguage = try #require(json["sourceLanguage"] as? String)
            strings = try #require(json["strings"] as? [String: [String: Any]])
        }

        /// Every language with at least one translation, the source excluded.
        var languages: Set<String> {
            Set(strings.values.flatMap { Array((($0["localizations"] as? [String: Any]) ?? [:]).keys) })
                .subtracting([sourceLanguage])
        }

        /// The entries that need a translation: a string that is not
        /// language (`%@` alone, a symbol) is marked `shouldTranslate: false`.
        var translatable: [String: [String: Any]] {
            strings.filter { $0.value["shouldTranslate"] as? Bool != false }
        }
    }

    /// The translated values of one entry in one language: the plain value,
    /// or each variation of a plural or device variation.
    private static func values(_ entry: [String: Any], language: String) -> [String]? {
        guard let localization = (entry["localizations"] as? [String: Any])?[language] as? [String: Any] else { return nil }
        return units(localization).compactMap { unit in
            unit["state"] as? String == "translated" ? unit["value"] as? String : nil
        }
    }

    private static func units(_ node: [String: Any]) -> [[String: Any]] {
        if let unit = node["stringUnit"] as? [String: Any] { return [unit] }
        guard let variations = node["variations"] as? [String: [String: [String: Any]]] else { return [] }
        return variations.values.flatMap(\.values).flatMap(units)
    }

    /// The format specifiers of a string, without their positions, in order
    /// of kind: `%1$@ %2$lld` and `%@ %lld` are the same set.
    private static func placeholders(_ text: String) -> [String] {
        let pattern = #/%(?:\d+\$)?(l{0,2}[dDuUxXoO]|[@fFeEgGcsSp])/#
        return text.matches(of: pattern).map { String($0.output.1) }.sorted()
    }

    @Test
    func every_string_has_a_translation_in_every_language() throws {
        for name in ["Localizable", "InfoPlist"] {
            let catalog = try Catalog(name)
            #expect(catalog.languages.contains("ko"), "\(name).xcstrings has no Korean")
            for language in catalog.languages {
                let missing = catalog.translatable.keys.filter { key in
                    Self.values(catalog.translatable[key] ?? [:], language: language)?.isEmpty ?? true
                }
                #expect(missing.isEmpty, "\(name).xcstrings has no \(language) for: \(missing.sorted())")
            }
        }
    }

    @Test
    func every_translation_keeps_the_placeholders_of_its_string() throws {
        let catalog = try Catalog("Localizable")
        for language in catalog.languages {
            for (key, entry) in catalog.translatable {
                for value in Self.values(entry, language: language) ?? [] {
                    #expect(
                        Self.placeholders(value) == Self.placeholders(key),
                        "\(language) for \"\(key)\" is \"\(value)\""
                    )
                }
            }
        }
    }

    /// The English values of the permission prompts are the text of
    /// `Info.plist`, so the catalog cannot show other English text, and each
    /// prompt has an entry.
    @Test
    func the_info_plist_catalog_matches_info_plist() throws {
        let url = Self.root.appendingPathComponent("Macterm/Info.plist")
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let catalog = try Catalog("InfoPlist")
        let prompts = plist.keys.filter { $0.hasSuffix("UsageDescription") }
        #expect(Set(prompts) == Set(catalog.strings.keys))
        for key in prompts {
            let english = Self.values(catalog.strings[key] ?? [:], language: "en")
            #expect(english == [plist[key] as? String].compactMap(\.self), "\(key)")
        }
    }

    /// The bundle carries each language, so macOS offers it and the menus
    /// that AppKit adds (Edit, Window, Help) follow the language too.
    @Test
    func the_bundle_carries_korean() throws {
        #expect(Bundle.main.localizations.contains("ko"))
        let path = try #require(Bundle.main.path(forResource: "ko", ofType: "lproj"))
        let korean = try #require(Bundle(path: path))
        #expect(korean.localizedString(forKey: "New Tab", value: nil, table: nil) != "New Tab")
    }

    /// `AppCommand.englishTitle` sets the locale of a `LocalizedStringResource`
    /// to pick the language. This shows that the locale does pick it.
    @Test
    func a_resource_locale_picks_the_language_of_the_lookup() {
        var resource: LocalizedStringResource = "New Tab"
        resource.locale = Locale(identifier: "ko")
        #expect(String(localized: resource) != "New Tab")
        resource.locale = Locale(identifier: "en")
        #expect(String(localized: resource) == "New Tab")
        #expect(AppCommand.newTab.englishTitle == "New Tab")
    }
}
