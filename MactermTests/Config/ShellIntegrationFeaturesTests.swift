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
