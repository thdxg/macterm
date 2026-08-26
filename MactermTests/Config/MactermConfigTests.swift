@testable import Macterm
import Testing

/// Pins the `macterm-overrides.conf` wire contract with libghostty — most
/// importantly the fork's `background-default-transparent` key (patch 0004),
/// which is what lets `background-opacity` carry the real window opacity
/// without double-tinting. If these lines drift, translucency breaks in ways
/// that only show up visually.
@MainActor
struct MactermConfigTests {
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
