import Foundation

/// The running app's bundle identifier — `com.thdxg.macterm.debug` in debug
/// builds, `com.thdxg.macterm` in release (see `project.yml`). Used as the
/// os.Logger subsystem so the two builds log to distinct subsystems
/// (`scripts/logs.sh`). Falls back to the release ID in non-bundle contexts
/// (e.g. unit tests).
let appBundleID = Bundle.main.bundleIdentifier ?? "com.thdxg.macterm"
