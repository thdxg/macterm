import Foundation

/// Whether the user's own Ghostty config asks to be notified.
///
/// This exists for one question the Settings pane needs to answer: is it worth
/// telling this user that macOS is dropping Macterm's notifications? Everyone
/// who has never granted the permission is technically affected — Macterm posts
/// on a finished command whatever the config says — but a banner shown to every
/// such user is nagware. Someone who wrote a notification key into their config
/// has said they care, and is the person for whom silent notifications are a
/// bug rather than a non-event.
///
/// So the predicate is "asked **for** notifications", not "mentioned
/// notifications". `desktop-notifications = false` and
/// `notify-on-command-finish = never` are configuration *against* them, and
/// nagging that person about a permission they don't want is worse than staying
/// quiet.
enum NotificationConfigIntent {
    /// Keys deliberately NOT consulted:
    ///
    /// - `app-notifications` — despite the name it governs Ghostty's own in-app
    ///   toasts (`clipboard-copy`, `config-reload`), which never reach
    ///   `UNUserNotificationCenter`.
    /// - `notify-on-command-finish-after` — a threshold. On its own it enables
    ///   nothing, so it can't carry the intent.
    /// - `bell-features` — the bell is `NSSound`/dock attention
    ///   (`GhosttyCallbacks.ringBell`), a separate path that needs no
    ///   notification permission at all.
    static func wantsNotifications(inConfigText text: String?) -> Bool {
        guard let text else { return false }

        // Default `true`, so only an explicit true states the intent — and an
        // explicit false states the opposite.
        if let value = GhosttyConfigText.lastValue(of: "desktop-notifications", inConfigText: text),
           GhosttyConfigText.trueLiterals.contains(value)
        {
            return true
        }

        // Default `never`. Both other values mean "notify me".
        if let value = GhosttyConfigText.lastValue(of: "notify-on-command-finish", inConfigText: text),
           ["unfocused", "always"].contains(value.lowercased())
        {
            return true
        }

        if let value = GhosttyConfigText.lastValue(
            of: "notify-on-command-finish-action",
            inConfigText: text
        ), requestsNotifyAction(value) {
            return true
        }

        return false
    }

    /// `notify-on-command-finish-action` is a packed struct (`bell` defaulting
    /// on, `notify` defaulting off) with the same grammar as
    /// `shell-integration-features`: comma parts applied left to right, a `no-`
    /// prefix turning one off, and a bool literal — valid only as the entire
    /// value — flipping every flag at once. Only `notify` posts a notification;
    /// `bell` rings the terminal bell, which needs no permission.
    private static func requestsNotifyAction(_ value: String) -> Bool {
        if GhosttyConfigText.trueLiterals.contains(value) { return true }
        if GhosttyConfigText.falseLiterals.contains(value) { return false }
        var wantsNotify = false
        for part in value.split(separator: ",") {
            let flag = part.trimmingCharacters(in: .whitespaces)
            if flag == "notify" { wantsNotify = true }
            if flag == "no-notify" { wantsNotify = false }
        }
        return wantsNotify
    }
}
