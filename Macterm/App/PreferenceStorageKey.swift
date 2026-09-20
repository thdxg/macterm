import Foundation
import SwiftUI

/// A UserDefaults-backed setting: its key, its default and any
/// normalization, declared once.
///
/// Before this, every `Preferences` property spelled its key in `Keys`, its
/// default in `init`, its read shape there too (`defaults.bool` for one,
/// `object(forKey:) as? Bool ?? false` for the next), its write in `didSet`,
/// and — for the sidebar views bound through `@AppStorage` — the default a
/// third time as a literal. Four places to disagree per setting. Here the
/// key owns all of it: `read` is the one read (absent → default, present →
/// normalized), `write` the one write, and `AppStorage.init(_:)` below feeds
/// the same default and store to a view.
struct PreferenceStorageKey<Value: PreferenceValue> {
    let name: String
    let defaultValue: Value
    /// Applied to a *stored* value on read — clamps, mostly. Never to the
    /// default, which is trusted as written.
    private let normalize: @Sendable (Value) -> Value

    init(_ name: String, default defaultValue: Value, normalize: @escaping @Sendable (Value) -> Value = { $0 }) {
        self.name = name
        self.defaultValue = defaultValue
        self.normalize = normalize
    }

    /// The effective value: the stored one normalized, else the default.
    func read(_ defaults: UserDefaults) -> Value {
        readStored(defaults) ?? defaultValue
    }

    /// The stored value alone (normalized), nil when the key is absent or
    /// holds something of the wrong shape. For settings whose absence means
    /// something other than the default — a "never dragged" sidebar, a
    /// panel never moved.
    func readStored(_ defaults: UserDefaults) -> Value? {
        Value.readPreference(from: defaults, key: name).map(normalize)
    }

    func write(_ value: Value, to defaults: UserDefaults) {
        value.writePreference(to: defaults, key: name)
    }

    func remove(from defaults: UserDefaults) {
        defaults.removeObject(forKey: name)
    }
}

/// A type UserDefaults can hold for a `PreferenceStorageKey`. The primitives store
/// themselves; an enum stores its raw value.
protocol PreferenceValue: Sendable {
    static func readPreference(from defaults: UserDefaults, key: String) -> Self?
    func writePreference(to defaults: UserDefaults, key: String)
}

extension Bool: PreferenceValue {
    static func readPreference(from defaults: UserDefaults, key: String) -> Bool? {
        defaults.object(forKey: key) as? Bool
    }

    func writePreference(to defaults: UserDefaults, key: String) {
        defaults.set(self, forKey: key)
    }
}

extension Int: PreferenceValue {
    static func readPreference(from defaults: UserDefaults, key: String) -> Int? {
        defaults.object(forKey: key) as? Int
    }

    func writePreference(to defaults: UserDefaults, key: String) {
        defaults.set(self, forKey: key)
    }
}

extension Double: PreferenceValue {
    static func readPreference(from defaults: UserDefaults, key: String) -> Double? {
        defaults.object(forKey: key) as? Double
    }

    func writePreference(to defaults: UserDefaults, key: String) {
        defaults.set(self, forKey: key)
    }
}

extension String: PreferenceValue {
    static func readPreference(from defaults: UserDefaults, key: String) -> String? {
        defaults.string(forKey: key)
    }

    func writePreference(to defaults: UserDefaults, key: String) {
        defaults.set(self, forKey: key)
    }
}

extension PreferenceValue where Self: RawRepresentable, RawValue: PreferenceValue {
    static func readPreference(from defaults: UserDefaults, key: String) -> Self? {
        RawValue.readPreference(from: defaults, key: key).flatMap(Self.init(rawValue:))
    }

    func writePreference(to defaults: UserDefaults, key: String) {
        rawValue.writePreference(to: defaults, key: key)
    }
}

/// A view binding to a preference by its key — the way the sidebar rows
/// already bind — now with the key's own default and `Preferences.defaults`
/// (the test-isolated store), so a row and `Preferences` can never disagree
/// about either.
extension AppStorage where Value == Bool {
    init(_ key: PreferenceStorageKey<Value>) {
        self.init(wrappedValue: key.defaultValue, key.name, store: Preferences.defaults)
    }
}

extension AppStorage where Value == String {
    init(_ key: PreferenceStorageKey<Value>) {
        self.init(wrappedValue: key.defaultValue, key.name, store: Preferences.defaults)
    }
}

extension AppStorage where Value: PreferenceValue, Value: RawRepresentable, Value.RawValue == String {
    init(_ key: PreferenceStorageKey<Value>) {
        self.init(wrappedValue: key.defaultValue, key.name, store: Preferences.defaults)
    }
}
