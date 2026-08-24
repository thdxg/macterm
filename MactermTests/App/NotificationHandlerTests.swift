@testable import Macterm
import Testing
import UserNotifications

@MainActor
struct NotificationHandlerTests {
    @Test
    func requests_the_same_alert_and_sound_permissions_as_ghostty() {
        #expect(NotificationHandler.authorizationOptions == [.alert, .sound])
    }

    @Test
    func notification_content_uses_the_default_system_sound() {
        let content = NotificationHandler.makeContent(
            title: "Title",
            body: "Body",
            userInfo: [:]
        )

        #expect(content.sound?.isEqual(UNNotificationSound.default) == true)
    }

    @Test
    func foreground_notifications_present_with_a_banner_and_sound() {
        #expect(NotificationHandler.foregroundPresentationOptions == [.banner, .sound])
    }
}
