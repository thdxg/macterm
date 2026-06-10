import Foundation

/// Generates the two ghostty config files Macterm wraps around the user's
/// own Ghostty config. The user is the source of truth for every Ghostty
/// setting; Macterm provides first-launch defaults that the user overrides,
/// and a minimal must-win overrides file for keys Macterm can't let the
/// renderer control (background-opacity and background-blur — both required
/// for the window-level translucency in `WindowAppearance` — plus, when the
/// external ghostty CLI is missing, a shell-integration-features line that
/// merges the user's own value with the features Macterm must disable; see
/// `ShellIntegrationFeatures`).
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
    /// either file. The overrides also depend on the *user's* config content
    /// (the shell-integration-features merge), so `GhosttyApp.loadConfig`
    /// calls this before every load to pick up user edits.
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
        // and dies. If the real Ghostty.app is installed, point at its CLI so
        // the `path` feature works; otherwise disable the wrappers that need
        // the binary so they fall through to plain `ssh`.
        //
        // The ssh wrappers additionally need a *new enough* CLI: the bundled
        // shell integration calls `ghostty +ssh`, an action older builds (e.g.
        // 1.3.1) lack. A present-but-too-old CLI makes the wrapper fail with
        // "Ghostty failed to initialize!" — worse than plain `ssh`. So we gate
        // the ssh features on `+ssh` support specifically, independent of
        // whether the binary exists for the `path` feature.
        let cli = GhosttyCLI.standard
        var disabledFeatures: [String] = []
        if let binDir = cli.resolveBinDir() {
            overrides.append("env = GHOSTTY_BIN_DIR=\(binDir)")
        } else {
            disabledFeatures.append("no-path")
        }
        if cli.resolveSSHWrapperBinDir() == nil {
            disabledFeatures.append(contentsOf: ["no-ssh-env", "no-ssh-terminfo"])
        }
        if !disabledFeatures.isEmpty {
            // A bare `shell-integration-features = <ours>` would replace the
            // user's own value entirely — libghostty re-parses the key from
            // defaults on every occurrence — wiping user flags like
            // `no-cursor`. Re-emit the user's effective value with our forced
            // flags appended so only those change. (#75)
            let value = ShellIntegrationFeatures.overrideValue(
                userConfigText: userGhosttyConfigText(),
                disabled: disabledFeatures
            )
            if let value {
                overrides.append("shell-integration-features = \(value)")
            }
        }

        let body = overrides.joined(separator: "\n") + "\n"
        try? Data(body.utf8).write(to: overridesURL, options: .atomic)
    }

    /// The user's Ghostty config text, read for merging their
    /// `shell-integration-features` value into the overrides. nil when the
    /// user has disabled loading (empty path) or the file is unreadable.
    private func userGhosttyConfigText() -> String? {
        let path = Preferences.shared.expandedUserGhosttyConfigPath
        guard !path.isEmpty else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}
