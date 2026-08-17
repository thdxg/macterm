import Foundation

/// Detects whether the app has been granted Full Disk Access.
///
/// macOS has no API to ask TCC directly, so the standard technique is
/// attempting to open a file FDA protects. The probe files are all owned by
/// the user with readable modes, so a failed `open(2)` can only mean TCC
/// blocked it — plain UNIX permissions can't confound the verdict. Probing is
/// side-effect free: FDA is grant-only in System Settings, so a denied open
/// never triggers a permission prompt.
///
/// The verdict is `Bool?` because "nothing probeable exists" is a real state
/// (however unlikely — the user TCC database is created at first login): a
/// caller shown no evidence should stay quiet rather than nag about a grant
/// that may already be in place.
enum FullDiskAccess {
    /// Deep link to System Settings → Privacy & Security → Full Disk Access.
    /// Optional only to satisfy `URL(string:)` — the literal always parses;
    /// callers `if let` it.
    static let settingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    enum ProbeResult {
        /// The file opened — TCC let us through.
        case readable
        /// The file exists but `open(2)` failed — TCC denied it.
        case denied
        /// The file doesn't exist; says nothing about the grant.
        case missing
    }

    /// FDA-protected, user-owned files. The user TCC database always exists;
    /// Safari's store is a second witness in case that ever changes.
    private static let probePaths = [
        "Library/Application Support/com.apple.TCC/TCC.db",
        "Library/Safari/CloudTabs.db",
    ]

    /// The decision over a set of probe results — pure, so it's the tested
    /// piece. Any readable file proves the grant (a denial alongside it would
    /// be some other restriction, not FDA); any denial without one disproves
    /// it; all-missing is no evidence either way.
    static func verdict(_ results: [ProbeResult]) -> Bool? {
        if results.contains(.readable) { return true }
        if results.contains(.denied) { return false }
        return nil
    }

    /// Probe the real system. `nil` means no evidence — treat as granted.
    static func isGranted() -> Bool? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return verdict(probePaths.map { probe(home.appendingPathComponent($0).path) })
    }

    private static func probe(_ path: String) -> ProbeResult {
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return .readable
        }
        return errno == ENOENT ? .missing : .denied
    }
}
