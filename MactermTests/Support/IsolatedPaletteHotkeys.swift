import Foundation
@testable import Macterm

extension PaletteHotkeys {
    private static var isolatedCount = 0

    /// A keybind table that no other test sees: its own defaults suite,
    /// wiped when it is made, and no Carbon registration.
    ///
    /// The suite names repeat in each run (a count, not a UUID), so a run
    /// leaves no new preference files behind.
    static func isolated() -> PaletteHotkeys {
        isolatedCount += 1
        let name = "\(appBundleID).tests.palette-hotkeys.\(isolatedCount)"
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return PaletteHotkeys(defaults: suite, syncGlobalHotkeys: {})
    }
}
