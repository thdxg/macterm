import Foundation

/// Pure, side-effect-free selection of the ghostty resources directory for
/// `GHOSTTY_RESOURCES_DIR`.
///
/// Macterm ships the ghostty resources in its bundle under
/// `Contents/Resources/ghostty` (themes + shell-integration), with the compiled
/// terminfo DB at the sibling `Contents/Resources/terminfo` — the same layout a
/// real Ghostty.app uses. libghostty reads shell-integration/themes from
/// `GHOSTTY_RESOURCES_DIR` and derives `TERMINFO` as
/// `dirname(GHOSTTY_RESOURCES_DIR)/terminfo` at shell spawn, so pointing the env
/// var at `.../Resources/ghostty` makes terminfo resolve to `.../Resources/
/// terminfo` automatically. Missing/incorrect terminfo breaks key input and
/// TERM=xterm-ghostty (issues #39/#40).
///
/// This type contains only the *selection* logic — which candidate dir wins.
/// The `setenv`/`Bundle.main` side effects live in `GhosttyApp`, which feeds
/// candidates and a filesystem probe in here. Splitting it out keeps the logic
/// that broke in #39/#40 unit-testable.
struct GhosttyResourceResolver {
    /// Candidate resource dirs, highest priority first.
    let candidates: [String]
    /// Filesystem existence probe. Injected so tests don't touch disk.
    let fileExists: (String) -> Bool

    /// Pick the first candidate that contains `shell-integration/` (the marker
    /// that the ghostty resources are actually present). Returns nil when no
    /// candidate qualifies — caller should then unset `GHOSTTY_RESOURCES_DIR`.
    func resolve() -> String? {
        candidates.first { fileExists($0 + "/shell-integration") }
    }

    /// The compiled terminfo DB for a resolved resources dir: its *sibling*
    /// `terminfo`, exactly the derivation libghostty performs at shell spawn
    /// (`dirname(GHOSTTY_RESOURCES_DIR)/terminfo`). Deriving it the same way
    /// rather than naming a path keeps the one invariant #39/#40 turned on —
    /// if the layout ever moves, both derivations move together instead of
    /// silently disagreeing.
    ///
    /// Needed by anything that must read our own entry with a tool that isn't
    /// a spawned shell (`RemoteTerminfo` runs `infocmp` against it), since
    /// `TERMINFO` is deliberately never set in this process — see
    /// `GhosttyApp.resolveResources`.
    static func terminfoDirectory(forResourcesDir dir: String) -> String {
        (dir as NSString).deletingLastPathComponent + "/terminfo"
    }
}
