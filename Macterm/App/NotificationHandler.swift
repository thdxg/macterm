import os
import UserNotifications

private let logger = Logger(subsystem: appBundleID, category: "NotificationHandler")

@MainActor
final class NotificationHandler: NSObject, @preconcurrency UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()
    weak var appState: AppState?

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            if !granted {
                logger.notice("Macterm notification authorization denied")
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let userInfo = response.notification.request.content.userInfo
        guard let paneIDString = userInfo["paneID"] as? String,
              let paneID = UUID(uuidString: paneIDString),
              let projectIDString = userInfo["projectID"] as? String,
              let projectID = UUID(uuidString: projectIDString)
        else { return }
        let isQuickTerminal = userInfo["isQuickTerminal"] as? Bool ?? false
        if isQuickTerminal {
            QuickTerminalService.shared.showPanel()
            if QuickTerminalService.shared.splitState.tab.splitRoot.findPane(id: paneID) != nil {
                QuickTerminalService.shared.splitState.tab.focusPane(paneID)
                FocusRestoration.restoreFocus(
                    to: paneID,
                    in: QuickTerminalService.shared.splitState.tab.splitRoot,
                    window: QuickTerminalService.shared.panel
                )
            }
        } else {
            appState?.navigateToPane(paneID, projectID: projectID)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}
