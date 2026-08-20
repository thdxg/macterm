import Foundation

/// Detects whether the app has been granted Full Disk Access.
///
/// macOS has no API to ask TCC directly, so the check is attempting to open
/// something FDA protects. **The probes must be directories, not files** —
/// measured on macOS 27, TCC *hides* protected files rather than denying them:
/// `open(2)` on `~/Library/Application Support/com.apple.TCC/TCC.db` or
/// `~/Library/Safari/CloudTabs.db` fails with `ENOENT` while the files plainly
/// exist, so a file probe can never observe a denial — it reads every denial
/// as "missing" and the verdict degrades to "no evidence" forever (the v1.24.0
/// banner never appeared because of exactly this). Protected *directories*
/// (`~/Library/Safari`, `~/Library/Mail`, `~/Library/Messages`, all verified)
/// fail with `EPERM` instead, which is a real, observable denial. All are
/// user-owned with traversable modes, so plain UNIX permissions can't confound
/// the verdict. Probing is side-effect free: FDA is grant-only in System
/// Settings, so a denied open never triggers a permission prompt.
///
/// The verdict is `Bool?` because "nothing probeable exists" is a real state
/// (a pristine account may lack some of these directories): a caller shown no
/// evidence should stay quiet rather than nag about a grant it can't
/// disprove. Note ENOENT is also what TCC's file-hiding returns, so a hidden
/// path and an absent one are indistinguishable by design — which is why the
/// probe list is several directories: one EPERM anywhere is proof enough.
enum FullDiskAccess {
    /// Deep link to System Settings → Privacy & Security → Full Disk Access.
    /// Optional only to satisfy `URL(string:)` — the literal always parses;
    /// callers `if let` it.
    static let settingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

    enum ProbeResult {
        /// The directory opened — TCC let us through.
        case readable
        /// `open(2)` failed with something other than ENOENT — TCC denied it.
        case denied
        /// ENOENT: absent, or a TCC-hidden file; says nothing either way.
        case missing
    }

    /// FDA-protected, user-owned directories (see the type comment for why
    /// directories). Safari's exists on effectively every account; Mail and
    /// Messages back it up on unusual ones.
    private static let probePaths = [
        "Library/Safari",
        "Library/Mail",
        "Library/Messages",
    ]

    /// The decision over a set of probe results — pure, so it's the tested
    /// piece. Any readable directory proves the grant (a denial alongside it
    /// would be some other restriction, not FDA); any denial without one
    /// disproves it; all-missing is no evidence either way.
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

    static func probe(_ path: String) -> ProbeResult {
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return .readable
        }
        return errno == ENOENT ? .missing : .denied
    }
}
