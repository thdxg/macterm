import AppKit
import LocalAuthentication
import os

private let logger = Logger(subsystem: appBundleID, category: "PasswordAuthenticator")

/// The gate in front of every saved-password read: Touch ID, or the login
/// password where there is no Touch ID (`.deviceOwnerAuthentication`). The
/// Keychain can't enforce this itself (see `KeychainPasswordStore`), so it is
/// the app's job, asked for at the moment of use.
///
/// Under `PasswordAutofillAuthentication.untilLocked` one success stands until
/// the screen locks, the Mac sleeps, the setting changes, or Macterm quits.
@MainActor
final class PasswordAuthenticator {
    static let shared = PasswordAuthenticator()

    private var unlocked = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {
        let relock: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { PasswordAuthenticator.shared.lock() }
        }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            (distributed, distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: relock)),
            (workspace, workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: relock)),
            (
                workspace,
                workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: relock)
            ),
        ]
    }

    func lock() {
        if unlocked { logger.info("locked") }
        unlocked = false
    }

    /// Ask the user to authenticate for `reason` (completes the system's
    /// "Macterm is trying to …" sentence) unless the standing unlock covers it.
    func authorize(reason: String) async -> Bool {
        let policy = Preferences.shared.passwordAutofillAuthentication
        if policy == .untilLocked, unlocked { return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            logger.warning("authentication unavailable: \(error?.localizedDescription ?? "unknown", privacy: .public)")
            return false
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            unlocked = ok && Preferences.shared.passwordAutofillAuthentication == .untilLocked
            return ok
        } catch {
            logger.info("authentication declined: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
