import Foundation

/// Which sessions run an older build than the app (design/002, option A).
/// A session keeps the build that started it, and an update never changes
/// it. The tab shows one badge for it, and Restart Session cures it.
///
/// The build of a session is the version string of its server build
/// (`1.0.1+thdxg.<key>`). The app compares the key with the key of the
/// bundled server (`ServerBuilds.bundledKey`). Two keys that differ mean
/// another build. Each build flavor has its own runtime folder, so a session
/// of another build is an older one. If either side has no key, nothing is
/// known, and nothing is marked.
enum SessionBuild {
    /// The build key in a session's reported build, or nil for any other
    /// string (`unknown`, an upstream binary).
    static func key(of build: String?) -> String? {
        build.flatMap(ZmxVersion.parse)?.forkTag
    }

    /// Whether `build` is another build than the one with key `appKey`.
    static func isOlder(_ build: String?, appKey: String?) -> Bool {
        guard let appKey, let sessionKey = key(of: build) else { return false }
        return sessionKey != appKey
    }

    /// The names of the running sessions that are older than the app.
    static func outdatedNames(in sessions: [LocalSession], appKey: String?) -> Set<String> {
        Set(sessions.filter { $0.isRunning && isOlder($0.build, appKey: appKey) }.map(\.name))
    }
}
