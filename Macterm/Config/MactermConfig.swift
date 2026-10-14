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
///   defaults → user's Ghostty config files → `~/.config/macterm/config.ghostty` → overrides
/// libghostty does last-wins merge, so the user wins over our defaults, the
/// user's Macterm-only file (`MactermConfigFile`) wins over their Ghostty
/// config, and our overrides win over both.
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
        // The user's own layer. Seeded once, here, so it exists before the
        // first load; never under a hermetic run, which also never loads it.
        if !Self.isHermetic {
            MactermConfigFile.seedIfMissing()
        }
    }

    /// True under unit tests and the benchmark and e2e harnesses. The user
    /// layers — the Ghostty config and `~/.config/macterm/config.ghostty` —
    /// are neither loaded nor read as text then, so a run is reproducible on
    /// any Mac. To verify a user-config feature live, use a throwaway `HOME`
    /// with `MACTERM_BENCHMARK_DATA_DIR` and no `MACTERM_BENCHMARK`.
    static var isHermetic: Bool {
        Preferences.isTestRun || BenchmarkControl.isEnabled
    }

    /// `~/.config/macterm/config.ghostty`, the layer after the Ghostty config
    /// (`MactermConfigFile`), or nil under a hermetic run. Every
    /// `GhosttyConfigSource` built for the live app passes this, so the
    /// loader and every raw-text reader see the same layers.
    static var userConfigPath: String? {
        isHermetic ? nil : MactermConfigFile.defaultURL().path
    }

    var defaultsPath: String { defaultsURL.path }
    var overridesPath: String { overridesURL.path }

    /// Rewrite both wrapper config files. Cheap and idempotent; safe to call
    /// on launch and whenever Macterm-side state changes that's reflected in
    /// either file. The overrides also depend on the *user's* config content
    /// (the shell-integration-features merge), so `GhosttyApp.loadConfig`
    /// calls this before every load to pick up user edits.
    func regenerate() {
        write(Data(Self.defaultsBody.utf8), to: defaultsURL)

        let userConfigText = userGhosttyConfigText()
        let body = Self.overridesBody(
            windowOpacity: Preferences.shared.windowOpacity,
            userConfigText: userConfigText,
            shimDirectory: Self.sshShimDirectory(),
            animations: .init(
                smoothScrolling: Preferences.shared.smoothScrolling,
                smoothScrollRows: Preferences.shared.snapScrollToRow,
                smoothCursor: Preferences.shared.smoothCursor,
                trail: Preferences.shared.cursorTrail
            )
        )
        write(Data(body.utf8), to: overridesURL)
    }

    /// The Settings → Animations toggles that are ghostty-side switches the
    /// overrides file flips, each a fork key the renderer reads. Smooth
    /// scrolling ships on; the two cursor effects are opt-in, so a user who
    /// never opens the pane gets the user-config cursor behavior.
    ///
    /// - Smooth scrolling is `smooth-scroll`: libghostty already accumulates
    ///   precise trackpad deltas in pixels, and with the key on it renders
    ///   the sub-row remainder. Macterm forwards every wheel event untouched
    ///   (#393), so the gate must live on that side.
    /// - Snap to whole row is `smooth-scroll-rows`, a mode of the same key:
    ///   input commits whole rows as it does without smooth scrolling, and
    ///   each row the viewport moves eases into place on the curve `less`'s
    ///   region scrolls use, so the viewport never rests between rows. The
    ///   renderer owns the motion; written only under `smooth-scroll`, which
    ///   it modifies.
    /// - Smooth cursor is `smooth-cursor`: the renderer's own cell shaders
    ///   draw the focused cursor at an eased rectangle and color the text
    ///   under it by coverage, so a glyph the cursor is halfway across is
    ///   two-toned. It replaced a custom shader that could only move a block
    ///   over an already-composited frame (the destination glyph was
    ///   cursor-colored from the first frame, and a partly covered cell's
    ///   own background was lost), and the `cursor-opacity = 0` override
    ///   that shader needed.
    /// - Cursor trail is `cursor-trail`: the streak behind the same motion,
    ///   drawn by the background shader under the text. It replaced a
    ///   bundled custom shader, which cost a full re-render of every frame
    ///   at the display's refresh for as long as it was loaded (libghostty
    ///   animates any custom shader continuously while focused) and could
    ///   only read the cursor's cell, not where the glide had drawn it.
    struct Animations: Equatable {
        var smoothScrolling = false
        var smoothScrollRows = false
        var smoothCursor = false
        var trail = false

        static let none = Animations()

        var overrideLines: [String] {
            var lines: [String] = []
            if smoothScrolling {
                lines.append("smooth-scroll = true")
                if smoothScrollRows {
                    lines.append("smooth-scroll-rows = true")
                }
            }
            if smoothCursor {
                lines.append("smooth-cursor = true")
            }
            if trail {
                lines.append("cursor-trail = true")
            }
            return lines
        }
    }

    /// One line of the defaults layer, with the note that
    /// `MactermConfigFile.template` prints above its commented copy. The note
    /// is user-facing text: it says what the key does and why Macterm's
    /// default differs from ghostty's, in Simplified Technical English.
    struct Default: Equatable {
        let line: String
        let note: String
    }

    /// The defaults layer, line by line: the one table behind both
    /// `macterm-defaults.conf` (`defaultsBody`, loaded first) and the
    /// commented template of `~/.config/macterm/config.ghostty`
    /// (`MactermConfigFile`), so the two can never drift. The user's Ghostty
    /// config overrides any line here without needing to know it exists. Two
    /// kinds of line live in it:
    ///
    /// - First-launch taste (theme, font size, padding).
    /// - **Macterm's default for a ghostty key Macterm itself applies**, where
    ///   that default departs from ghostty's. Macterm reads `macos-shortcuts`
    ///   and `tab-inherit-working-directory` / `split-inherit-working-directory`
    ///   for its own behavior and has no Settings UI for them; when its
    ///   behavior should differ from ghostty's by default, the difference is a
    ///   line here — never a fallback in `Preferences` — so the user changes
    ///   it the same way as any other key.
    ///
    /// Anything we'd set to ghostty's own default (e.g. `scrollbar = system`,
    /// `split-inherit-working-directory = true`) isn't listed — libghostty
    /// already does the right thing. `MactermConfigTests` pins the departures.
    static let defaults: [Default] = [
        .init(
            line: "theme = \"Rose Pine\"",
            note: "The color theme: the name of a theme that Ghostty bundles, or the path to a theme file."
        ),
        .init(
            line: "font-size = 16",
            note: "The font size, in points."
        ),
        .init(
            line: "macos-option-as-alt = true",
            note: "The Option key sends Alt to the program in the pane. Set false to type special characters with it."
        ),
        .init(
            line: "window-padding-x = 16",
            note: "The space between the text and the left and right edges of a pane, in points."
        ),
        .init(
            line: "window-padding-y = 16",
            note: "The space between the text and the top and bottom edges of a pane, in points."
        ),
        // A new tab starts at the project root; ghostty would start it in the
        // focused surface's cwd. Splits keep ghostty's `true`.
        .init(
            line: "tab-inherit-working-directory = false",
            note: "A new tab starts at the project root. Set true to start it in the directory of the focused pane, as Ghostty does.\n"
                + "Splits always start in the directory of the pane that you split."
        ),
        // Secure input still engages at a password prompt; the per-pane lock
        // badge doesn't draw. The password bubble already marks the prompt,
        // and the badge sat over the pane's content.
        .init(
            line: "macos-secure-input-indication = false",
            note: "The lock badge that Ghostty draws on a pane at a password prompt. Secure input itself stays on.\n"
                + "The password bubble of Macterm already marks the prompt."
        ),
    ]

    /// The full text of `macterm-defaults.conf`, the first config layer: the
    /// lines of `defaults`, nothing else.
    static let defaultsBody: String = defaults.map(\.line).joined(separator: "\n") + "\n"

    /// The full text of `macterm-overrides.conf`. Pure — live inputs are
    /// passed in — so the wire contract with libghostty (most importantly the
    /// fork's `background-default-transparent` key) is unit-testable without
    /// touching disk.
    static func overridesBody(
        windowOpacity: Double,
        userConfigText: String?,
        shimDirectory: String?,
        animations: Animations = .none
    ) -> String {
        var overrides = [
            // Macterm composites window translucency at the AppKit level —
            // ghostty must not paint the default background or we'd double-
            // tint. See WindowAppearance.swift. This fork key skips exactly
            // that paint (the same renderer mechanism ghostty's own macOS
            // glass styles use) while leaving `background-opacity`
            // meaningful for everything else.
            "background-default-transparent = true",
            // The real window opacity, so the user's own
            // `background-opacity-cells` flag works as ghostty documents it:
            // TUI-painted cell backgrounds become translucent at the window
            // opacity. Before the fork key existed this was pinned to 0 —
            // which that flag multiplies into every painted cell, turning
            // them invisible instead of translucent. Kept current by the
            // debounced reload in `Preferences.windowOpacity`.
            "background-opacity = \(windowOpacity)",
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
        if let shimDirectory {
            overrides.append("env = GHOSTTY_BIN_DIR=\(shimDirectory)")
        } else {
            disabledFeatures.append(contentsOf: ["no-ssh-env", "no-ssh-terminfo"])
        }
        // A bare `shell-integration-features = no-path` would replace the
        // user's own value entirely — libghostty re-parses the key from
        // defaults on every occurrence — wiping user flags like `no-cursor`.
        // Re-emit the user's effective value with our forced flags appended
        // so only those change. (#75)
        let value = ShellIntegrationFeatures.overrideValue(
            userConfigText: userConfigText,
            disabled: disabledFeatures
        )
        if let value {
            overrides.append("shell-integration-features = \(value)")
        }

        overrides.append(contentsOf: animations.overrideLines)

        return overrides.joined(separator: "\n") + "\n"
    }

    /// Write a wrapper-config file, logging on failure. These writes are
    /// behavior-changing — a failed overrides write silently breaks the
    /// translucency contract (`background-default-transparent` never lands,
    /// causing double-tinting) — so a swallowed `try?` would leave zero
    /// diagnostics.
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

    /// The user's root-config text in load order — the Ghostty files, then
    /// `~/.config/macterm/config.ghostty` — read for merging their
    /// `shell-integration-features` value into the overrides. nil when
    /// loading is disabled or none of the selected files is readable.
    ///
    /// Static so anything else that must consult the user's *stated* config
    /// reads it the same way — `RemoteTerminfo`'s gate deliberately reads this
    /// raw text rather than the effective post-override value.
    static func userGhosttyConfigText() -> String? {
        guard !isHermetic else { return nil }
        return GhosttyConfigSource(
            selection: Preferences.shared.ghosttyConfigSelection,
            mactermConfigPath: userConfigPath
        ).mergedText()
    }

    private func userGhosttyConfigText() -> String? {
        Self.userGhosttyConfigText()
    }
}
