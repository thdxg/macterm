import Foundation

/// Generates the two ghostty config files Macterm wraps around the user's
/// own Ghostty config. The user is the source of truth for every Ghostty
/// setting; Macterm provides first-launch defaults that the user overrides,
/// and a minimal must-win overrides file for keys Macterm can't let the
/// renderer control (currently: background-opacity, background-blur — both
/// required for the window-level translucency in `WindowAppearance`).
///
/// `GhosttyApp.loadConfig` loads them in this order:
///   defaults → user's Ghostty config → overrides
/// libghostty does last-wins merge, so the user wins over our defaults and
/// our overrides win over the user.
///
/// See the README for the full list of Ghostty config settings Macterm honors
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
            // First-launch tasteful UX. User's Ghostty config overrides any of
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

        var overrides = [
            // Macterm composites window translucency at the AppKit level —
            // ghostty must draw a fully transparent terminal or we'd double-
            // tint. See WindowAppearance.swift.
            "background-opacity = 0",
            // We call CGSSetWindowBackgroundBlurRadius ourselves; ghostty's
            // own blur would compose on top of it.
            "background-blur = 0",
        ]

        // libghostty auto-populates `GHOSTTY_BIN_DIR` in spawned shells from
        // the host executable's directory — for us that's Macterm's bundle,
        // which ships no `ghostty` CLI. The shell-integration `ssh` wrapper
        // then tries to exec a non-existent `Macterm.app/Contents/MacOS/ghostty`
        // and dies. If the real Ghostty.app is installed, point at its CLI;
        // otherwise disable the wrappers that need the binary so they fall
        // through to plain `ssh`. The `path` feature also relies on this dir
        // being useful — turn it off when we have nothing to add.
        if let binDir = resolveGhosttyBinDir() {
            overrides.append("env = GHOSTTY_BIN_DIR=\(binDir)")
        } else {
            overrides.append("shell-integration-features = no-ssh-env,no-ssh-terminfo,no-path")
        }

        let body = overrides.joined(separator: "\n") + "\n"
        try? Data(body.utf8).write(to: overridesURL, options: .atomic)
    }

    private func resolveGhosttyBinDir() -> String? {
        let candidates = [
            "/Applications/Ghostty.app/Contents/MacOS",
            NSHomeDirectory() + "/Applications/Ghostty.app/Contents/MacOS",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0 + "/ghostty") }
    }
}
