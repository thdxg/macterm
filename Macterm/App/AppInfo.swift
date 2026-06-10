import Foundation

/// The running app's bundle identifier — `com.thdxg.macterm.debug` in debug
/// builds, `com.thdxg.macterm` in release (see `project.yml`). Used as the
/// os.Logger subsystem so the two builds log to distinct subsystems
/// (`scripts/logs.sh`). Falls back to the release ID in non-bundle contexts
/// (e.g. unit tests).
let appBundleID = Bundle.main.bundleIdentifier ?? "com.thdxg.macterm"

/// The running app's display name — "Macterm Debug" in debug builds, "Macterm"
/// in release (`PRODUCT_DISPLAY_NAME` in `project.yml` → `CFBundleDisplayName`).
/// Used wherever the app refers to itself by name — the Application Support
/// directory, window titles, dialogs — so the debug build keeps its own
/// identity and data, mirroring the bundle-ID split above. Falls back to the
/// release name in non-bundle contexts (e.g. unit tests).
let appDisplayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Macterm"
