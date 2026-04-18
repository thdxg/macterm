import Foundation

enum AutoTilePreference {
    static let key = "macterm.autoTiling.enabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func set(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
        NotificationCenter.default.post(name: .autoTilingEnabledDidChange, object: nil)
    }
}
