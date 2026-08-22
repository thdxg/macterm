import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "MactermConfig")

/// Generates the two ghostty config files Macterm wraps around the user's
/// own Ghostty config. The user is normally the source of truth for every
/// Ghostty setting; Macterm provides first-launch defaults that the user
/// overrides, and a minimal must-win overrides file for keys Macterm needs to
/// control. That includes background opacity/blur, compatibility fixes, and
/// the terminal background only when the user explicitly selects Macterm's
/// custom-color mode in Settings.
///
/// `GhosttyApp.loadConfig` loads them in this order:
///   defaults → user's Ghostty config files → overrides
/// libghostty does last-wins merge, so the user wins over our defaults and
/// our overrides win over the user.
///
/// See the README for the full list of Ghostty config settings Macterm honors
/// and the small set it ignores or overrides.
/// `@Observable` isn't applied: all stored state is `let` (nothing to observe),
/// and no view tracks this type. `@MainActor` isolation is kept for the singleton.
@MainActor
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
        write(Data(defaults.utf8), to: defaultsURL)

        var overrides = [
            // Macterm composites window translucency at the AppKit level —
            // ghostty must draw a fully transparent terminal or we'd double-
            // tint. See WindowAppearance.swift.
            "background-opacity = 0",
            // We call CGSSetWindowBackgroundBlurRadius ourselves; ghostty's
            // own blur would compose on top of it.
            "background-blur = 0",
        ]

        // The shell-integration `ssh` wrapper (the `ssh-env`/`ssh-terminfo`
        // features) execs `"$GHOSTTY_BIN_DIR/ghostty" +ssh` — an action
        // Macterm serves natively via the bundled `ghostty` shim, which
        // relays to `macterm ssh` (see SSHWrapper). Point GHOSTTY_BIN_DIR at
        // the shim's directory so those features work with no Ghostty.app
        // installed; libghostty would otherwise auto-populate it with the
        // host executable's directory (Contents/MacOS), where no `ghostty`
        // exists. Only if the shim is missing from the bundle (a broken or
        // partial build) are the ssh features forced off, so the wrapper
        // falls through to plain `ssh` instead of dying on a bad exec.
        //
        // `path` is always forced off: its sole effect is putting
        // GHOSTTY_BIN_DIR on PATH, and the shim answers nothing but `+ssh` —
        // exposing it as a bare `ghostty` would impersonate the real CLI.
        var disabledFeatures = ["no-path"]
        if let shimDir = Self.sshShimDirectory() {
            overrides.append("env = GHOSTTY_BIN_DIR=\(shimDir)")
        } else {
            disabledFeatures.append(contentsOf: ["no-ssh-env", "no-ssh-terminfo"])
        }
        // A bare `shell-integration-features = no-path` would replace the
        // user's own value entirely — libghostty re-parses the key from
        // defaults on every occurrence — wiping user flags like `no-cursor`.
        // Re-emit the user's effective value with our forced flags appended
        // so only those change. (#75)
        let value = ShellIntegrationFeatures.overrideValue(
            userConfigText: userGhosttyConfigText(),
            disabled: disabledFeatures
        )
        if let value {
            overrides.append("shell-integration-features = \(value)")
        }

        let body = overrides.joined(separator: "\n") + "\n"
        write(Data(body.utf8), to: overridesURL)
    }

    /// Write a wrapper-config file, logging on failure. These writes are
    /// behavior-changing — a failed overrides write silently breaks the
    /// translucency contract (`background-opacity = 0` never lands, causing
    /// double-tinting) — so a swallowed `try?` would leave zero diagnostics.
    private func write(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("failed to write \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// The bundle directory holding the `ghostty` shim that serves the
    /// shell-integration ssh wrapper (`scripts/ghostty-shim.sh`, installed by
    /// the "Bundle macterm CLI" post-build step), or nil when the shim isn't
    /// there — a broken or partial build, in which case `regenerate` forces
    /// the ssh features off rather than let the wrapper exec a missing file.
    /// Its own directory, NOT `Resources/bin` or `Contents/MacOS`, because
    /// both of those land on pane PATHs and a `ghostty` that only answers
    /// `+ssh` must never be reachable by name.
    static func sshShimDirectory() -> String? {
        guard let dir = Bundle.main.resourceURL?
            .appendingPathComponent("ssh-bridge", isDirectory: true)
        else { return nil }
        let shim = dir.appendingPathComponent("ghostty").path
        return FileManager.default.isExecutableFile(atPath: shim) ? dir.path : nil
    }

    /// The user's Ghostty root-config text in load order, read for merging
    /// their `shell-integration-features` value into the overrides. nil when
    /// loading is disabled or none of the selected files is readable.
    ///
    /// Static so anything else that must consult the user's *stated* config
    /// reads it the same way — `RemoteTerminfo`'s gate deliberately reads this
    /// raw text rather than the effective post-override value.
    static func userGhosttyConfigText() -> String? {
        guard !Preferences.isTestRun, !BenchmarkControl.isEnabled else { return nil }
        return GhosttyConfigSource(selection: Preferences.shared.ghosttyConfigSelection).mergedText()
    }

    private func userGhosttyConfigText() -> String? {
        Self.userGhosttyConfigText()
    }
}
