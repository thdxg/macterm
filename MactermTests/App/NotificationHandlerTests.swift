import Foundation
@testable import Macterm
import Testing
import UserNotifications

/// Pane notifications are a **contract with the system**, and every half of it
/// fails silently when it drifts:
///
/// - The authorization options decide, at first grant, whether a sound is even
///   permitted. Dropping `.sound` doesn't error — notifications just go mute.
/// - The foreground presentation options are the only thing that makes a
///   banner (and its sound) appear while Macterm is frontmost. Returning `[]`
///   swallows the notification with no trace.
/// - The `userInfo` keys are read back in `didReceive` by string. A rename
///   compiles fine and breaks tap-routing.
/// - `clearDelivered` finds a pane's notifications by *identifier prefix*
///   rather than tracking a live set, so the identifier shape is load-bearing.
///
/// So these tests pin the literals and the shape. What they deliberately do
/// NOT do is post anything: the suite runs hosted inside the debug app, where
/// `UNUserNotificationCenter.add` would deliver a real notification to the
/// developer's Notification Center. Everything asserted here is reachable
/// without touching the center.
@MainActor
struct NotificationHandlerTests {
    // MARK: - System contract

    @Test
    func requests_the_same_alert_and_sound_permissions_as_ghostty() {
        #expect(NotificationHandler.authorizationOptions == [.alert, .sound])
    }

    @Test
    func foreground_notifications_present_with_a_banner_and_sound() {
        #expect(NotificationHandler.foregroundPresentationOptions == [.banner, .sound])
    }

    @Test
    func category_and_action_identifiers_are_scoped_to_the_build_flavor() {
        // Debug and release are separate apps; a shared category identifier
        // would let one build's registration describe the other's banners.
        #expect(NotificationHandler.categoryIdentifier.hasPrefix(appBundleID))
        #expect(NotificationHandler.showActionIdentifier.hasPrefix(appBundleID))
        #expect(NotificationHandler.categoryIdentifier != NotificationHandler.showActionIdentifier)
    }

    // MARK: - Content

    @Test
    func notification_content_carries_the_sound_subtitle_and_category() {
        let content = NotificationHandler.makeContent(
            title: "Command Finished",
            subtitle: "npm",
            body: "Exited with code 1 (2.0s)",
            userInfo: ["paneID": "abc"]
        )

        #expect(content.title == "Command Finished")
        #expect(content.subtitle == "npm")
        #expect(content.body == "Exited with code 1 (2.0s)")
        #expect(content.sound?.isEqual(UNNotificationSound.default) == true)
        #expect(content.categoryIdentifier == NotificationHandler.categoryIdentifier)
        #expect(content.userInfo["paneID"] as? String == "abc")
    }

    @Test
    func user_info_carries_the_keys_did_receive_reads_back() {
        let pane = Pane(projectPath: "/tmp", projectID: UUID())
        let userInfo = NotificationHandler.userInfo(for: pane)

        #expect(userInfo["paneID"] as? String == pane.id.uuidString)
        #expect(userInfo["projectID"] as? String == pane.projectID.uuidString)
        #expect(userInfo["isQuickTerminal"] as? Bool == false)
    }

    @Test
    func a_quick_terminal_pane_is_flagged_so_taps_route_to_the_panel() {
        let pane = Pane(projectPath: "/tmp", projectID: QuickTerminalService.ephemeralProjectID)

        #expect(NotificationHandler.userInfo(for: pane)["isQuickTerminal"] as? Bool == true)
    }

    // MARK: - Identifiers

    @Test
    func each_post_gets_a_distinct_identifier_under_the_pane_prefix() {
        let paneID = UUID()
        let first = NotificationHandler.identifier(paneID: paneID)
        let second = NotificationHandler.identifier(paneID: paneID)

        // A reused identifier REPLACES the delivered notification instead of
        // adding one, so two commands finishing would show as one banner.
        #expect(first != second)
        #expect(first.hasPrefix(NotificationHandler.identifierPrefix(paneID: paneID)))
        #expect(second.hasPrefix(NotificationHandler.identifierPrefix(paneID: paneID)))
    }

    @Test
    func one_panes_prefix_never_matches_another_panes_identifier() {
        // This is what makes prefix-based clearing safe: focusing one pane must
        // not sweep away a sibling's notifications.
        let mine = UUID()
        let other = UUID()

        #expect(!NotificationHandler.identifier(paneID: other)
            .hasPrefix(NotificationHandler.identifierPrefix(paneID: mine)))
    }

    // MARK: - Response routing

    @Test
    func tapping_the_banner_or_the_show_action_navigates() {
        #expect(NotificationHandler.responseRoute(for: UNNotificationDefaultActionIdentifier) == .navigate)
        #expect(NotificationHandler.responseRoute(for: NotificationHandler.showActionIdentifier) == .navigate)
    }

    @Test
    func dismissing_a_notification_never_navigates() {
        // The category registers `.customDismissAction`, so dismissals reach
        // `didReceive` too. Treating them as taps would yank the user to a pane
        // because they swiped a banner away.
        #expect(NotificationHandler.responseRoute(for: UNNotificationDismissActionIdentifier) == .ignore)
        #expect(NotificationHandler.responseRoute(for: "com.example.unknown") == .ignore)
    }
}
