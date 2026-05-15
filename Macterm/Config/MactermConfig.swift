import Foundation

/// Generates the two ghostty config files Macterm wraps around the user's
/// own ghostty.conf. The user is the source of truth for every ghostty
/// setting; Macterm provides first-launch defaults that the user overrides,
/// and a minimal must-win overrides file for keys Macterm can't let the
/// renderer control (currently: background-opacity, background-blur — both
/// required for the window-level translucency in `WindowAppearance`).
///
/// `GhosttyApp.loadConfig` loads them in this order:
///   defaults → user's ghostty.conf → overrides
/// libghostty does last-wins merge, so the user wins over our defaults and
/// our overrides win over the user.
///
/// See the README for the full list of ghostty.conf settings Macterm honors
/// and the small set it ignores or overrides.
@MainActor @Observable
final class MactermConfig {
    static let shared = MactermConfig()

    let defaultsURL: URL
    let overridesURL: URL

    private init() {
        let dir = FileStorage.appSupportDirectory()
        defaultsURL = dir.appendingPathComponent("macterm-defaults.conf")
        overridesURL = dir.appendingPathComponent("macterm-overrides.conf")
        regenerate()
    }

    var defaultsPath: String { defaultsURL.path }
    var overridesPath: String { overridesURL.path }

    /// Rewrite both wrapper config files. Cheap and idempotent; safe to call
    /// on launch and whenever Macterm-side state changes that's reflected in
    /// either file.
    func regenerate() {
        let defaults = [
            // First-launch tasteful UX. User's ghostty.conf overrides any of
            // these without needing to know they exist. Anything we'd set to
            // ghostty's own default (e.g. scrollbar=system) isn't listed —
            // libghostty already does the right thing.
            "theme = \"Rose Pine\"",
            "font-size = 16",
            "macos-option-as-alt = true",
            "window-padding-x = 16",
            "window-padding-y = 16",
        ].joined(separator: "\n") + "\n"
        try? Data(defaults.utf8).write(to: defaultsURL, options: .atomic)

        let overrides = [
            // Macterm composites window translucency at the AppKit level —
            // ghostty must draw a fully transparent terminal or we'd double-
            // tint. See WindowAppearance.swift.
            "background-opacity = 0",
            // We call CGSSetWindowBackgroundBlurRadius ourselves; ghostty's
            // own blur would compose on top of it.
            "background-blur = 0",
        ].joined(separator: "\n") + "\n"
        try? Data(overrides.utf8).write(to: overridesURL, options: .atomic)
    }
}
