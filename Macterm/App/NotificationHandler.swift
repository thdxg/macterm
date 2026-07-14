import os
import UserNotifications

private let logger = Logger(subsystem: appBundleID, category: "NotificationHandler")

/// The delegate methods are `nonisolated` (they can be called off-main) and
/// hand off to the main actor explicitly via a `Task { @MainActor }`, instead
/// of a `@preconcurrency` conformance that would silently disable isolation
/// checking. Only Sendable values (the notification's String/Bool fields) cross
/// the boundary — the non-Sendable `response`/`completionHandler` stay on the
/// calling side — so Swift 6 concurrency checking stays ON.
@MainActor
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()
    weak var appState: AppState?

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            if !granted {
                logger.notice("Macterm notification authorization denied")
            }
        }
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Extract only Sendable values (Strings/Bool) from the non-Sendable
        // `response` HERE on the nonisolated side, and complete synchronously —
        // so nothing non-Sendable crosses the actor boundary (which Swift 6
        // rejects as a data-race risk). Then hop just those values to the main
        // actor. This keeps isolation checking ON instead of papering over the
        // off-main delivery with a `@preconcurrency` conformance.
        let userInfo = response.notification.request.content.userInfo
        let paneIDString = userInfo["paneID"] as? String
        let projectIDString = userInfo["projectID"] as? String
        let isQuickTerminal = userInfo["isQuickTerminal"] as? Bool ?? false
        completionHandler()

        guard let paneIDString, let paneID = UUID(uuidString: paneIDString),
              let projectIDString, let projectID = UUID(uuidString: projectIDString)
        else { return }
        Task { @MainActor in
            Self.shared.handleTap(paneID: paneID, projectID: projectID, isQuickTerminal: isQuickTerminal)
        }
    }

    private func handleTap(paneID: UUID, projectID: UUID, isQuickTerminal: Bool) {
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

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}
