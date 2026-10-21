import Foundation

/// The "Macterm updated to vX" toast on the first launch after an update.
///
/// Sparkle installs an update while the app quits (`automaticallyDownloadsUpdates`)
/// or relaunches it from the update prompt, and neither path leaves anything in
/// the app that says the version changed. The rule is a comparison against the
/// version that the previous launch recorded (`Preferences.lastLaunchedVersion`).
///
/// No recorded version means a fresh install, or the first launch of a build
/// that has this feature. Neither is an update the user can know about, so
/// that launch only records.
enum UpdateNotice {
    /// The toast title for this launch, or nil when the version did not change.
    static func title(previous: String?, current: String) -> String? {
        guard let previous, !previous.isEmpty, previous != current else { return nil }
        return String(localized: "Macterm updated to v\(current)")
    }
}

extension AppState {
    /// Show the update toast if this launch runs a new version, and record the
    /// version for the next launch. Runs one time, from `MainWindow`'s launch
    /// task.
    ///
    /// Skipped under `MACTERM_BENCHMARK=1`: the harnesses run a Release build
    /// in the real defaults domain, and their `0.0.0` would make the next real
    /// launch report an update.
    func presentUpdateNoticeIfNeeded() {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard !BenchmarkControl.isEnabled, let currentVersion, !currentVersion.isEmpty else { return }
        let previous = Preferences.shared.lastLaunchedVersion
        if previous != currentVersion { Preferences.shared.lastLaunchedVersion = currentVersion }
        if let title = UpdateNotice.title(previous: previous, current: currentVersion) {
            presentToast(title)
        }
    }
}
