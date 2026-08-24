@testable import Macterm
import Testing

/// The banner these back is a nag if it fires on the wrong config, and useless
/// if it stays quiet on the right one — and the user only ever sees the verdict,
/// never the reasoning. So each case here is a config someone plausibly writes.
///
/// The asymmetry worth remembering: `desktop-notifications` defaults to **true**
/// and `notify-on-command-finish` defaults to **never**, so "not mentioned"
/// means opposite things for the two keys and neither can be read as intent.
struct NotificationConfigIntentTests {
    @Test
    func a_config_that_never_mentions_notifications_states_no_intent() {
        #expect(NotificationConfigIntent.wantsNotifications(inConfigText: nil) == false)
        #expect(NotificationConfigIntent.wantsNotifications(inConfigText: "") == false)
        #expect(NotificationConfigIntent.wantsNotifications(
            inConfigText: "theme = catppuccin-mocha\nfont-size = 13"
        ) == false)
    }

    @Test
    func asking_for_desktop_notifications_states_intent() {
        #expect(NotificationConfigIntent.wantsNotifications(inConfigText: "desktop-notifications = true"))
        #expect(NotificationConfigIntent.wantsNotifications(inConfigText: "desktop-notifications = 1"))
    }

    @Test
    func turning_notifications_off_is_not_intent() {
        // The case that separates "asked for notifications" from "mentioned
        // notifications". Warning this user about a permission they don't want
        // is worse than saying nothing.
        #expect(NotificationConfigIntent.wantsNotifications(
            inConfigText: "desktop-notifications = false"
        ) == false)
        #expect(NotificationConfigIntent.wantsNotifications(
            inConfigText: "notify-on-command-finish = never"
        ) == false)
    }

    @Test
    func command_finish_notifications_state_intent_unless_never() {
        #expect(NotificationConfigIntent.wantsNotifications(inConfigText: "notify-on-command-finish = always"))
        #expect(NotificationConfigIntent.wantsNotifications(inConfigText: "notify-on-command-finish = unfocused"))
    }

    @Test
    func the_finish_action_states_intent_only_when_it_names_notify() {
        // `bell` is the default and rings NSSound — no permission involved.
        #expect(NotificationConfigIntent.wantsNotifications(
            inConfigText: "notify-on-command-finish-action = bell"
        ) == false)
        #expect(NotificationConfigIntent.wantsNotifications(
            inConfigText: "notify-on-command-finish-action = bell,notify"
        ))
        // Later parts win per flag, same grammar as shell-integration-features.
        #expect(NotificationConfigIntent.wantsNotifications(
            inConfigText: "notify-on-command-finish-action = notify,no-notify"
        ) == false)
        // A bool literal is valid only as the whole value and flips every flag.
        #expect(NotificationConfigIntent.wantsNotifications(
            inConfigText: "notify-on-command-finish-action = true"
        ))
    }

    @Test
    func a_threshold_alone_is_not_intent() {
        // `notify-on-command-finish-after` tunes a threshold; on its own it
        // enables nothing, so it can't carry the intent.
        #expect(NotificationConfigIntent.wantsNotifications(
            inConfigText: "notify-on-command-finish-after = 10s"
        ) == false)
    }

    @Test
    func app_notifications_is_not_a_desktop_notification_key() {
        // Despite the name it governs Ghostty's in-app toasts (clipboard-copy,
        // config-reload), which never reach UNUserNotificationCenter.
        #expect(NotificationConfigIntent.wantsNotifications(
            inConfigText: "app-notifications = clipboard-copy,config-reload"
        ) == false)
    }

    @Test
    func the_bell_is_a_separate_path_that_needs_no_permission() {
        #expect(NotificationConfigIntent.wantsNotifications(
            inConfigText: "bell-features = system,audio"
        ) == false)
    }

    @Test
    func the_last_occurrence_of_a_key_wins() {
        #expect(NotificationConfigIntent.wantsNotifications(
            inConfigText: "desktop-notifications = true\ndesktop-notifications = false"
        ) == false)
        #expect(NotificationConfigIntent.wantsNotifications(
            inConfigText: "desktop-notifications = false\ndesktop-notifications = true"
        ))
    }

    @Test
    func an_empty_value_resets_the_key_rather_than_setting_it() {
        // libghostty's own semantics: `key =` restores the default, so the
        // preceding explicit intent is withdrawn, not kept.
        #expect(NotificationConfigIntent.wantsNotifications(
            inConfigText: "notify-on-command-finish = always\nnotify-on-command-finish ="
        ) == false)
    }

    @Test
    func commented_out_intent_is_not_intent() {
        #expect(NotificationConfigIntent.wantsNotifications(
            inConfigText: "# desktop-notifications = true"
        ) == false)
    }

    @Test
    func quoted_and_padded_values_still_parse() {
        #expect(NotificationConfigIntent.wantsNotifications(
            inConfigText: "  notify-on-command-finish   =   \"always\"  "
        ))
    }

    @Test
    func a_longer_key_that_merely_starts_the_same_is_not_a_match() {
        // `notify-on-command-finish-after` must not be read as
        // `notify-on-command-finish` — the parser compares whole keys.
        #expect(NotificationConfigIntent.wantsNotifications(
            inConfigText: "notify-on-command-finish-after = always"
        ) == false)
    }
}
