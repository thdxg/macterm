import Foundation
@testable import Macterm
import Testing

/// `PreferenceStorageKey` is the one read and one write for a setting, so
/// these pin what "absent", "stored" and "normalized" mean once, for every
/// `Preferences` property at the same time.
struct PreferenceStorageKeyTests {
    private func isolatedDefaults() throws -> UserDefaults {
        let suiteName = "com.thdxg.macterm.storage-key-tests.\(UUID().uuidString)"
        return try #require(UserDefaults(suiteName: suiteName))
    }

    @Test
    func absent_reads_as_the_default_and_stored_reads_back() throws {
        let defaults = try isolatedDefaults()
        let key = PreferenceStorageKey("test.flag", default: true)

        #expect(key.read(defaults) == true)
        #expect(key.readStored(defaults) == nil)

        key.write(false, to: defaults)
        #expect(key.read(defaults) == false)
        #expect(key.readStored(defaults) == false)

        key.remove(from: defaults)
        #expect(key.read(defaults) == true)
        #expect(key.readStored(defaults) == nil)
    }

    @Test
    func a_value_of_the_wrong_shape_reads_as_absent() throws {
        let defaults = try isolatedDefaults()
        let key = PreferenceStorageKey("test.count", default: 7)
        defaults.set("not a number", forKey: key.name)
        #expect(key.read(defaults) == 7)
        #expect(key.readStored(defaults) == nil)
    }

    @Test
    func normalize_applies_to_stored_values_only() throws {
        let defaults = try isolatedDefaults()
        // The default is trusted as written even when it sits outside what
        // `normalize` would allow — a stored value is what gets clamped.
        let key = PreferenceStorageKey("test.fraction", default: 5.0) { min(1, max(0, $0)) }
        #expect(key.read(defaults) == 5.0)
        key.write(2.5, to: defaults)
        #expect(key.read(defaults) == 1.0)
        #expect(key.readStored(defaults) == 1.0)
    }

    @Test
    func an_enum_round_trips_through_its_raw_value() throws {
        let defaults = try isolatedDefaults()
        let key = PreferenceStorageKey("test.channel", default: UpdateChannel.stable)
        key.write(.tip, to: defaults)
        #expect(defaults.string(forKey: key.name) == "tip")
        #expect(key.read(defaults) == .tip)
        // A raw value no case owns — a newer build's — falls back to the default.
        defaults.set("nightly", forKey: key.name)
        #expect(key.read(defaults) == .stable)
    }

    @Test
    func every_preferences_key_has_a_distinct_name() {
        // Two settings sharing a defaults key would silently overwrite each
        // other; the table is the only place the names live now.
        let names = [
            Preferences.Keys.autoTiling.name, Preferences.Keys.smoothScrolling.name,
            Preferences.Keys.windowOpacity.name, Preferences.Keys.sidebarWidth.name,
            Preferences.Keys.quickTerminalWidth.name, Preferences.Keys.quickTerminalHeight.name,
            Preferences.Keys.activeProjectID.name, Preferences.Keys.updateChannel.name,
            Preferences.Keys.recentTabCandidates.name, Preferences.Keys.sidebarIconSize.name,
        ]
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0.hasPrefix("macterm.") })
    }
}
