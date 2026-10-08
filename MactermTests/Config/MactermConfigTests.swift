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

    /// Secure input at a password prompt stays on; only ghostty's lock badge
    /// is off by default, and the user's config can turn it back on.
    @Test
    func secure_input_badge_is_off_by_default() {
        #expect(MactermConfig.defaultsBody.contains("macos-secure-input-indication = false\n"))
        #expect(!MactermConfig.defaultsBody.contains("macos-auto-secure-input"))
    }

    /// Scrolling is libghostty's on every path (the #102 accumulator is gone),
    /// so `mouse-scroll-multiplier` keeps ghostty's own default — and
    /// `macos-shortcuts` defaults to `ask` in both. A pin would be noise.
    @Test
    func keys_that_share_ghosttys_default_are_not_pinned() {
        #expect(!MactermConfig.defaultsBody.contains("mouse-scroll-multiplier"))
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

    // MARK: - overridesBody: animations

    @Test
    func smooth_scrolling_is_the_fork_key() {
        let body = MactermConfig.overridesBody(
            windowOpacity: 1.0, userConfigText: nil, shimDirectory: nil,
            animations: .init(smoothScrolling: true)
        )
        #expect(body.contains("smooth-scroll = true\n"))
        #expect(!body.contains("custom-shader"))
    }

    @Test
    func snap_to_whole_row_is_the_forks_rows_mode_of_smooth_scrolling() {
        let body = MactermConfig.overridesBody(
            windowOpacity: 1.0, userConfigText: nil, shimDirectory: nil,
            animations: .init(smoothScrolling: true, smoothScrollRows: true)
        )
        #expect(body.contains("smooth-scroll = true\n"))
        #expect(body.contains("smooth-scroll-rows = true\n"))
        // Pixel smooth scrolling alone leaves the rows key to the user.
        let pixels = MactermConfig.overridesBody(
            windowOpacity: 1.0, userConfigText: nil, shimDirectory: nil,
            animations: .init(smoothScrolling: true)
        )
        #expect(!pixels.contains("smooth-scroll-rows"))
    }

    @Test
    func snap_to_whole_row_without_smooth_scrolling_writes_nothing() {
        let body = MactermConfig.overridesBody(
            windowOpacity: 1.0, userConfigText: nil, shimDirectory: nil,
            animations: .init(smoothScrolling: false, smoothScrollRows: true)
        )
        #expect(!body.contains("smooth-scroll"))
    }

    @Test
    func smooth_scrolling_off_writes_no_key_so_the_user_config_decides() {
        let body = MactermConfig.overridesBody(windowOpacity: 1.0, userConfigText: nil, shimDirectory: nil)
        #expect(!body.contains("smooth-scroll"))
    }

    @Test
    func cursor_effects_off_emit_nothing() {
        let body = MactermConfig.overridesBody(
            windowOpacity: 1.0, userConfigText: nil, shimDirectory: nil,
            animations: .init(smoothCursor: false, trail: false)
        )
        #expect(!body.contains("smooth-cursor"))
        #expect(!body.contains("cursor-trail"))
        #expect(!body.contains("custom-shader"))
        #expect(!body.contains("cursor-opacity"))
    }

    @Test
    func smooth_cursor_is_the_forks_key_and_touches_no_shader_or_opacity() {
        let body = MactermConfig.overridesBody(
            windowOpacity: 1.0, userConfigText: nil, shimDirectory: nil,
            animations: .init(smoothCursor: true, trail: false)
        )
        #expect(body.contains("smooth-cursor = true\n"))
        #expect(!body.contains("cursor-trail"))
        #expect(!body.contains("custom-shader"))
        #expect(!body.contains("cursor-opacity"))
    }

    @Test
    func cursor_trail_is_the_forks_key_with_or_without_the_glide() {
        let both = MactermConfig.overridesBody(
            windowOpacity: 1.0, userConfigText: nil, shimDirectory: nil,
            animations: .init(smoothCursor: true, trail: true)
        )
        #expect(both.contains("smooth-cursor = true\ncursor-trail = true\n"))
        let alone = MactermConfig.overridesBody(
            windowOpacity: 1.0, userConfigText: nil, shimDirectory: nil,
            animations: .init(smoothCursor: false, trail: true)
        )
        #expect(alone.contains("cursor-trail = true\n"))
        #expect(!alone.contains("smooth-cursor"))
        #expect(!alone.contains("custom-shader"))
    }
}
