@testable import Macterm
import Testing

struct ShellIntegrationFeaturesTests {
    // MARK: - userValue(inConfigText:)

    @Test
    func reads_features_line() {
        let text = "font-size = 16\nshell-integration-features = no-cursor\ntheme = Rose Pine\n"
        #expect(ShellIntegrationFeatures.userValue(inConfigText: text) == "no-cursor")
    }

    @Test
    func last_line_wins() {
        let text = "shell-integration-features = no-cursor\nshell-integration-features = no-title,sudo\n"
        #expect(ShellIntegrationFeatures.userValue(inConfigText: text) == "no-title,sudo")
    }

    @Test
    func empty_value_resets_to_unset() {
        let text = "shell-integration-features = no-cursor\nshell-integration-features = \n"
        #expect(ShellIntegrationFeatures.userValue(inConfigText: text) == nil)
    }

    @Test
    func ignores_comments_and_blanks() {
        let text = "# shell-integration-features = ignored\n\n  shell-integration-features = no-cursor  \n"
        #expect(ShellIntegrationFeatures.userValue(inConfigText: text) == "no-cursor")
    }

    @Test
    func strips_surrounding_quotes() {
        let text = "shell-integration-features = \"no-cursor,sudo\"\n"
        #expect(ShellIntegrationFeatures.userValue(inConfigText: text) == "no-cursor,sudo")
    }

    @Test
    func no_line_returns_nil() {
        #expect(ShellIntegrationFeatures.userValue(inConfigText: "font-size = 16\n") == nil)
    }

    @Test
    func does_not_match_other_keys() {
        #expect(ShellIntegrationFeatures.userValue(inConfigText: "shell-integration = zsh\n") == nil)
    }

    // MARK: - overrideValue(userConfigText:disabled:)

    // MARK: - isEnabled(_:inConfigText:)

    @Test
    func unmentioned_features_fall_back_to_ghosttys_own_defaults() {
        // Not a uniform "off": read off `ghostty +show-config --default` on the
        // pinned build — cursor,no-sudo,title,no-ssh-env,no-ssh-terminfo,path.
        // ssh-terminfo defaulting OFF is what makes gating the native remote
        // installer on this flag match ghostty's behavior instead of quietly
        // writing terminfo to hosts nobody asked us to touch.
        for text in [nil, "font-size = 16\n"] as [String?] {
            #expect(ShellIntegrationFeatures.isEnabled("ssh-terminfo", inConfigText: text) == false)
            #expect(ShellIntegrationFeatures.isEnabled("ssh-env", inConfigText: text) == false)
            #expect(ShellIntegrationFeatures.isEnabled("sudo", inConfigText: text) == false)
            #expect(ShellIntegrationFeatures.isEnabled("cursor", inConfigText: text) == true)
            #expect(ShellIntegrationFeatures.isEnabled("title", inConfigText: text) == true)
            #expect(ShellIntegrationFeatures.isEnabled("path", inConfigText: text) == true)
        }
        // An unknown flag can't be assumed on.
        #expect(ShellIntegrationFeatures.isEnabled("not-a-feature", inConfigText: nil) == false)
    }

    @Test
    func isEnabled_applies_flags_left_to_right_with_no_prefix_winning() {
        // The real-world value this was built for.
        let user = "shell-integration-features = sudo,ssh-env,ssh-terminfo,no-title\n"
        #expect(ShellIntegrationFeatures.isEnabled("ssh-terminfo", inConfigText: user) == true)
        #expect(ShellIntegrationFeatures.isEnabled("ssh-env", inConfigText: user) == true)
        #expect(ShellIntegrationFeatures.isEnabled("title", inConfigText: user) == false)
        // Unmentioned flags keep their default even when the key is set.
        #expect(ShellIntegrationFeatures.isEnabled("cursor", inConfigText: user) == true)
        // Later parts win per-flag, like libghostty's own merge.
        let flip = "shell-integration-features = ssh-terminfo,no-ssh-terminfo\n"
        #expect(ShellIntegrationFeatures.isEnabled("ssh-terminfo", inConfigText: flip) == false)
        let flop = "shell-integration-features = no-ssh-terminfo,ssh-terminfo\n"
        #expect(ShellIntegrationFeatures.isEnabled("ssh-terminfo", inConfigText: flop) == true)
        // A flag whose name merely contains ours must not match it.
        let other = "shell-integration-features = ssh-env\n"
        #expect(ShellIntegrationFeatures.isEnabled("ssh", inConfigText: other) == false)
    }

    @Test
    func isEnabled_honors_bool_literals_and_the_last_line() {
        #expect(ShellIntegrationFeatures.isEnabled(
            "ssh-terminfo", inConfigText: "shell-integration-features = true\n"
        ) == true)
        #expect(ShellIntegrationFeatures.isEnabled(
            "cursor", inConfigText: "shell-integration-features = false\n"
        ) == false)
        // An empty value resets the key to "not set", so defaults apply again.
        #expect(ShellIntegrationFeatures.isEnabled(
            "ssh-terminfo", inConfigText: "shell-integration-features = ssh-terminfo\nshell-integration-features =\n"
        ) == false)
        #expect(ShellIntegrationFeatures.isEnabled(
            "ssh-terminfo", inConfigText: "shell-integration-features = false\nshell-integration-features = ssh-terminfo\n"
        ) == true)
    }

    @Test
    func no_disabled_features_needs_no_override() {
        let text = "shell-integration-features = no-cursor\n"
        #expect(ShellIntegrationFeatures.overrideValue(userConfigText: text, disabled: []) == nil)
    }

    @Test
    func no_user_config_emits_only_disabled() {
        let value = ShellIntegrationFeatures.overrideValue(
            userConfigText: nil,
            disabled: ["no-ssh-env", "no-ssh-terminfo"]
        )
        #expect(value == "no-ssh-env,no-ssh-terminfo")
    }

    @Test
    func no_user_line_emits_only_disabled() {
        let value = ShellIntegrationFeatures.overrideValue(
            userConfigText: "font-size = 16\n",
            disabled: ["no-path"]
        )
        #expect(value == "no-path")
    }

    @Test
    func user_flags_are_preserved_before_disabled() {
        // The issue #75 case: user's no-cursor must survive the override.
        let value = ShellIntegrationFeatures.overrideValue(
            userConfigText: "shell-integration-features = no-cursor\n",
            disabled: ["no-ssh-env", "no-ssh-terminfo"]
        )
        #expect(value == "no-cursor,no-ssh-env,no-ssh-terminfo")
    }

    @Test
    func disabled_flags_come_last_so_they_win() {
        // ghostty applies parts left to right; a user-enabled ssh-env must
        // still lose to our forced no-ssh-env.
        let value = ShellIntegrationFeatures.overrideValue(
            userConfigText: "shell-integration-features = ssh-env,no-cursor\n",
            disabled: ["no-ssh-env"]
        )
        #expect(value == "ssh-env,no-cursor,no-ssh-env")
    }

    @Test
    func bare_true_expands_to_all_features() {
        // A bool literal is only valid as the whole value, so "all on" has to
        // become an explicit list before our flags can be appended.
        let value = ShellIntegrationFeatures.overrideValue(
            userConfigText: "shell-integration-features = true\n",
            disabled: ["no-path"]
        )
        #expect(value == "cursor,sudo,title,ssh-env,ssh-terminfo,path,no-path")
    }

    @Test
    func bare_false_stays_false() {
        // Everything off already includes everything we'd disable.
        for literal in ["false", "0", "f", "F"] {
            let value = ShellIntegrationFeatures.overrideValue(
                userConfigText: "shell-integration-features = \(literal)\n",
                disabled: ["no-ssh-env"]
            )
            #expect(value == "false")
        }
    }

    @Test
    func true_literal_variants_expand() {
        for literal in ["1", "t", "T", "true"] {
            let value = ShellIntegrationFeatures.overrideValue(
                userConfigText: "shell-integration-features = \(literal)\n",
                disabled: ["no-ssh-env"]
            )
            #expect(value == "cursor,sudo,title,ssh-env,ssh-terminfo,path,no-ssh-env")
        }
    }

    @Test
    func last_user_line_is_the_one_merged() {
        let text = "shell-integration-features = no-title\nshell-integration-features = no-cursor\n"
        let value = ShellIntegrationFeatures.overrideValue(
            userConfigText: text,
            disabled: ["no-path"]
        )
        #expect(value == "no-cursor,no-path")
    }
}
