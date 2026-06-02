import Foundation

/// Pure, side-effect-free resolution of the ghostty resources directory and the
/// terminfo database within Macterm's bundle.
///
/// libghostty reads two things at runtime via `GHOSTTY_RESOURCES_DIR`:
/// `shell-integration/` (mandatory) and `terminfo/` (mandatory for
/// `TERM=xterm-ghostty` to resolve — without it key input and TERM break, see
/// issues #39/#40). `themes/` is read only when using named themes. Macterm
/// ships all three in its own bundle so it works with no Ghostty.app install.
///
/// This type contains only the *selection* logic — which candidate dir wins and
/// where TERMINFO should point. The actual `setenv`/`Bundle.main` side effects
/// live in `GhosttyApp`, which feeds candidates and a filesystem probe in here.
/// Splitting it out keeps the logic that broke in #39/#40 unit-testable.
struct GhosttyResourceResolver {
    /// Candidate resource dirs, highest priority first.
    let candidates: [String]
    /// Macterm's own bundle resources dir (`Bundle.main.resourceURL`), if any.
    /// TERMINFO is only set when the resolved dir is this one — for a Ghostty.app
    /// fallback, libghostty's own `dirname(resourcesDir)/terminfo` derivation is
    /// already correct, so we leave TERMINFO alone.
    let bundleResourcesDir: String?
    /// Filesystem existence probe. Injected so tests don't touch disk.
    let fileExists: (String) -> Bool

    struct Resolution: Equatable {
        /// Value for `GHOSTTY_RESOURCES_DIR`.
        var resourcesDir: String
        /// Value for `TERMINFO`, or nil to leave the env var untouched.
        var terminfoDir: String?
    }

    /// Pick the first candidate that contains `shell-integration/` (the marker
    /// that the ghostty resources are actually present). Returns nil when no
    /// candidate qualifies — caller should then unset `GHOSTTY_RESOURCES_DIR`.
    func resolve() -> Resolution? {
        guard let dir = candidates.first(where: { fileExists($0 + "/shell-integration") }) else {
            return nil
        }
        return Resolution(resourcesDir: dir, terminfoDir: terminfo(for: dir))
    }

    /// TERMINFO path for a resolved dir: only our own bundle, and only when the
    /// `terminfo/` tree is actually present.
    private func terminfo(for resourcesDir: String) -> String? {
        guard resourcesDir == bundleResourcesDir else { return nil }
        let terminfo = resourcesDir + "/terminfo"
        return fileExists(terminfo) ? terminfo : nil
    }
}
