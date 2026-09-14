@testable import Macterm
import Testing

/// Pins the `macterm-overrides.conf` wire contract with libghostty — most
/// importantly the fork's `background-default-transparent` key (patch 0004),
/// which is what lets `background-opacity` carry the real window opacity
/// without double-tinting. If these lines drift, translucency breaks in ways
/// that only show up visually.
@MainActor
struct MactermConfigTests {
    // MARK: - defaultsBody: Macterm's defaults for the ghostty keys it applies

    /// Ghostty starts a new tab in the focused surface's cwd; Macterm starts it
    /// at the project root. That is a defaults-layer line, not a `Preferences`
    /// fallback, so the user's config overrides it the ordinary way.
    @Test
    func new_tabs_start_at_the_project_root_by_default() {
        #expect(MactermConfig.defaultsBody.contains("tab-inherit-working-directory = false\n"))
        // Splits keep ghostty's default (inherit), so nothing is written.
        #expect(!MactermConfig.defaultsBody.contains("split-inherit-working-directory"))
    }

    /// Macterm's scrollback has always moved one row per wheel notch where
    /// ghostty's discrete default is three. The pin and the resolver's
    /// fallback must agree, or an unset key and the shipped default would
    /// scroll differently.
    @Test
    func scroll_multiplier_pin_matches_the_resolver_fallback() {
        #expect(MactermConfig.defaultsBody.contains("mouse-scroll-multiplier = precision:1,discrete:1\n"))
        #expect(MouseScrollMultiplier.resolve(userConfigText: MactermConfig.defaultsBody) == .mactermDefault)
    }

    /// `macos-shortcuts` defaults to `ask` in both; a pin would be noise.
    @Test
    func shortcuts_access_is_not_pinned() {
        #expect(!MactermConfig.defaultsBody.contains("macos-shortcuts"))
    }

    // MARK: - overridesBody: the translucency contract

    @Test
    func never_paints_default_background() {
        let body = MactermConfig.overridesBody(windowOpacity: 1.0, userConfigText: nil, shimDirectory: nil)
        #expect(body.contains("background-default-transparent = true"))
    }

    @Test
    func window_opacity_is_the_real_background_opacity() {
        let body = MactermConfig.overridesBody(windowOpacity: 0.85, userConfigText: nil, shimDirectory: nil)
        #expect(body.contains("background-opacity = 0.85"))
    }

    @Test
    func full_opacity_is_written_as_one_not_the_old_zero_pin() {
        // The pre-fork contract pinned `background-opacity = 0`, which
        // `background-opacity-cells` multiplies into every painted cell —
        // turning them invisible. The pin must never resurface.
        let body = MactermConfig.overridesBody(windowOpacity: 1.0, userConfigText: nil, shimDirectory: nil)
        #expect(body.contains("background-opacity = 1.0"))
        #expect(!body.contains("background-opacity = 0\n"))
    }

    @Test
    func ghostty_blur_stays_off() {
        // Macterm calls the CGS blur SPI itself; ghostty's blur would
        // compose on top of it.
        let body = MactermConfig.overridesBody(windowOpacity: 0.5, userConfigText: nil, shimDirectory: nil)
        #expect(body.contains("background-blur = 0"))
    }

    // MARK: - overridesBody: ssh shim plumbing

    @Test
    func shim_directory_feeds_ghostty_bin_dir_and_keeps_ssh_features() {
        let body = MactermConfig.overridesBody(windowOpacity: 1.0, userConfigText: nil, shimDirectory: "/tmp/shim")
        #expect(body.contains("env = GHOSTTY_BIN_DIR=/tmp/shim"))
        #expect(body.contains("shell-integration-features = no-path"))
        #expect(!body.contains("no-ssh-env"))
    }

    @Test
    func missing_shim_forces_ssh_features_off() {
        let body = MactermConfig.overridesBody(windowOpacity: 1.0, userConfigText: nil, shimDirectory: nil)
        #expect(!body.contains("GHOSTTY_BIN_DIR"))
        #expect(body.contains("shell-integration-features = no-path,no-ssh-env,no-ssh-terminfo"))
    }

    @Test
    func user_features_survive_the_merge() {
        let user = "shell-integration-features = no-cursor\n"
        let body = MactermConfig.overridesBody(windowOpacity: 1.0, userConfigText: user, shimDirectory: "/tmp/shim")
        #expect(body.contains("shell-integration-features = no-cursor,no-path"))
    }
}
