import os
import UserNotifications

private let logger = Logger(subsystem: appBundleID, category: "NotificationHandler")

/// Owns BOTH ends of a pane notification: the content and `userInfo` written by
/// `post`, and the routing read back in `didReceive`. They are one contract —
/// splitting the write across another file is how a key rename silently breaks
/// tap-routing while everything still compiles.
///
/// The delegate methods are `nonisolated` (they can be called off-main) and
/// hand off to the main actor explicitly via a `Task { @MainActor }`, instead
/// of a `@preconcurrency` conformance that would silently disable isolation
/// checking. Only Sendable values (the notification's String/Bool fields) cross
/// the boundary — the non-Sendable `response`/`completionHandler` stay on the
/// calling side — so Swift 6 concurrency checking stays ON.
@MainActor
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()
    static let authorizationOptions: UNAuthorizationOptions = [.alert, .sound]
    nonisolated static let foregroundPresentationOptions: UNNotificationPresentationOptions = [.banner, .sound]

    /// The one category every pane notification carries. Bundle-ID-scoped so a
    /// debug build's registration can't collide with the release app's, the
    /// same split the logger subsystem uses.
    nonisolated static let categoryIdentifier = "\(appBundleID).userNotification"
    /// The explicit "Show" button, alongside clicking the banner body.
    nonisolated static let showActionIdentifier = "\(appBundleID).userNotification.Show"

    weak var appState: AppState?

    /// Panes that have posted a notification which may still be sitting in
    /// Notification Center. Purely a fast path: `clearDelivered` runs on every
    /// pane focus change, and without this every one of those would spend an
    /// XPC round-trip to notificationd only to learn there is nothing to
    /// remove. (Ghostty guards the same call with its per-surface identifier
    /// set.) Membership is allowed to be stale in the conservative direction —
    /// a notification the user dismissed, or that aged out on its own, leaves
    /// the pane listed and costs one wasted lookup — but never in the other,
    /// because `post` is the only thing that inserts.
    private var panesWithNotifications: Set<UUID> = []

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: Self.authorizationOptions) { _, error in
            // Ghostty logs this error; swallowing it (as this did) makes a
            // failed request indistinguishable from a refused one.
            if let error {
                logger.error("Notification authorization request failed: \(error.localizedDescription, privacy: .public)")
            }
            Self.logNotificationSettings()
        }
    }

    /// Report what the system actually holds for us, because `granted` alone
    /// answers none of the questions a silent app raises. The system prompts
    /// **once per app, ever**: after that a request returns the standing answer
    /// without showing anything, so a denied app looks identical to one that
    /// was never asked, and only System Settings can undo it. `soundSetting` is
    /// the other half — an install that granted permission back when Macterm
    /// requested `[.alert]` alone can be authorized and still mute, which is
    /// exactly the upgrade path #298 introduced.
    ///
    /// Logged at `.notice` only when something is off, so a healthy launch
    /// stays quiet and a broken one leaves the answer in `mise run logs`.
    nonisolated private static func logNotificationSettings() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = describe(settings.authorizationStatus)
            let alert = describe(settings.alertSetting)
            let sound = describe(settings.soundSetting)
            guard settings.authorizationStatus != .authorized
                || settings.alertSetting != .enabled
                || settings.soundSetting != .enabled
            else {
                logger.info("Notifications ready (authorization=\(status, privacy: .public))")
                return
            }
            logger.notice("""
            Notifications degraded: authorization=\(status, privacy: .public) \
            alert=\(alert, privacy: .public) sound=\(sound, privacy: .public). \
            Fix in System Settings > Notifications > \(appDisplayName, privacy: .public).
            """)
        }
    }

    nonisolated private static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "not-determined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown(\(status.rawValue))"
        }
    }

    nonisolated private static func describe(_ setting: UNNotificationSetting) -> String {
        switch setting {
        case .notSupported: "not-supported"
        case .disabled: "disabled"
        case .enabled: "enabled"
        @unknown default: "unknown(\(setting.rawValue))"
        }
    }

    /// Register the pane-notification category. `.customDismissAction` is what
    /// makes the system deliver a *dismissal* to `didReceive` at all — without
    /// it only taps arrive, and `responseRoute` never sees the dismiss case.
    func registerCategories() {
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryIdentifier,
                actions: [UNNotificationAction(identifier: Self.showActionIdentifier, title: "Show")],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
        ])
    }

    // MARK: - Posting

    /// Post a notification for `pane` — the single path, so the desktop-
    /// notification and command-finished callers can't drift.
    func post(pane: Pane, title: String, body: String) {
        let request = UNNotificationRequest(
            identifier: Self.identifier(paneID: pane.id),
            content: Self.makeContent(
                title: title,
                subtitle: pane.displayTitle,
                body: body,
                userInfo: Self.userInfo(for: pane)
            ),
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        panesWithNotifications.insert(pane.id)
    }

    /// The routing-critical `userInfo` contract, read back by `didReceive`.
    static func userInfo(for pane: Pane) -> [AnyHashable: Any] {
        [
            "paneID": pane.id.uuidString,
            "projectID": pane.projectID.uuidString,
            "isQuickTerminal": pane.projectID == QuickTerminalService.ephemeralProjectID,
        ]
    }

    static func makeContent(
        title: String,
        subtitle: String,
        body: String,
        userInfo: [AnyHashable: Any]
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        // Which pane fired this — the same name its sidebar row shows, so the
        // notification and the row the user goes looking for agree (including
        // the static fallback when auto-naming is off).
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = userInfo
        return content
    }

    // MARK: - Identifiers

    /// Every identifier is `macterm-<paneID>-<unique>`, which makes a pane's
    /// delivered notifications findable by prefix. Ghostty instead keeps the
    /// live identifiers themselves in a per-surface `Set<String>`; deriving the
    /// lookup from the pane id means the set above can be a lossy hint rather
    /// than the source of truth, so a stale entry costs one wasted lookup
    /// instead of stranding a banner nothing can remove. The UUID suffix keeps
    /// each post distinct — a reused identifier would REPLACE the delivered
    /// notification rather than add one.
    nonisolated static func identifierPrefix(paneID: UUID) -> String {
        "macterm-\(paneID.uuidString)-"
    }

    nonisolated static func identifier(paneID: UUID) -> String {
        identifierPrefix(paneID: paneID) + UUID().uuidString
    }

    /// Drop this pane's already-delivered notifications from Notification
    /// Center. Called when the pane takes focus (the user has now seen it, so a
    /// "Command Finished" banner for it is stale) and when its surface is
    /// destroyed — both are what Ghostty does in `focusDidChange` and on
    /// surface removal.
    func clearDelivered(paneID: UUID) {
        guard panesWithNotifications.remove(paneID) != nil else { return }
        let prefix = Self.identifierPrefix(paneID: paneID)
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let stale = delivered.map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            guard !stale.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: stale)
        }
    }

    // MARK: - Delegate

    /// What a notification response should do. A dismissal must NOT navigate —
    /// registering `.customDismissAction` is what starts delivering those here,
    /// and treating every response as a tap would yank the user to a pane
    /// because they swiped a banner away.
    enum ResponseRoute: Equatable {
        case navigate
        case ignore
    }

    nonisolated static func responseRoute(for actionIdentifier: String) -> ResponseRoute {
        switch actionIdentifier {
        case UNNotificationDefaultActionIdentifier,
             showActionIdentifier: .navigate
        default: .ignore
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
        let route = Self.responseRoute(for: response.actionIdentifier)
        let paneIDString = userInfo["paneID"] as? String
        let projectIDString = userInfo["projectID"] as? String
        let isQuickTerminal = userInfo["isQuickTerminal"] as? Bool ?? false
        completionHandler()

        guard case .navigate = route else { return }
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
        completionHandler(Self.foregroundPresentationOptions)
    }
}
