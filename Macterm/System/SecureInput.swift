import AppKit
import Carbon
import os

private let logger = Logger(subsystem: appBundleID, category: "SecureInput")

/// Manages macOS secure keyboard input (the Carbon `EnableSecureEventInput`
/// API): while enabled, keystrokes go only to the focused app and are hidden
/// from event taps and keyboard monitors. Ported from Ghostty.app's manager;
/// the shape is dictated by the API's contract:
///
/// - It's global, process-scoped, and *counted* — every enable must be
///   balanced by exactly one disable, so a singleton owns the one on/off edge.
/// - It must be released while the app is inactive (it affects other apps)
///   and reacquired on activation, hence the NSApplication observers.
///
/// Two inputs decide the desired state: a `global` flag (the user's
/// `toggle_secure_input` keybind, app target) and per-surface scopes (a
/// terminal reporting a password prompt, enabled only while that surface has
/// keyboard focus). System-state calls are injectable so the balancing logic
/// is unit-testable without flipping real secure input under the test runner.
@MainActor
@Observable
final class SecureInput {
    static let shared = SecureInput()

    /// True while secure input is actually enabled at the OS level. Drives
    /// the per-pane lock indicator.
    private(set) var enabled = false

    /// User-requested global secure input (`toggle_secure_input` keybind).
    private(set) var global = false

    @ObservationIgnored
    private var scoped: [ObjectIdentifier: Bool] = [:]

    /// System hooks, injectable for tests. Defaults are the real Carbon calls
    /// and NSApp activity.
    @ObservationIgnored
    var enableHook: () -> OSStatus = { EnableSecureEventInput() }
    @ObservationIgnored
    var disableHook: () -> OSStatus = { DisableSecureEventInput() }
    @ObservationIgnored
    var isAppActive: () -> Bool = { NSApp.isActive }

    @ObservationIgnored
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        let becameActive = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidBecomeActive() }
        }
        let resignedActive = center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.appDidResignActive() }
        }
        observers = [becameActive, resignedActive]
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func setGlobal(_ on: Bool) {
        global = on
        logger.info("secure input global=\(on, privacy: .public)")
        apply()
    }

    func toggleGlobal() {
        setGlobal(!global)
    }

    /// Record that `object` (a surface on a password prompt) wants secure
    /// input, active only while it has keyboard focus.
    func setScoped(_ object: ObjectIdentifier, focused: Bool) {
        scoped[object] = focused
        logger.info("secure input scoped add focused=\(focused, privacy: .public)")
        apply()
    }

    /// Drop a scoped object entirely (password prompt ended, or the surface
    /// is being destroyed).
    func removeScoped(_ object: ObjectIdentifier) {
        scoped[object] = nil
        logger.info("secure input scoped remove")
        apply()
    }

    private var desired: Bool {
        global || scoped.contains { $0.value }
    }

    private func apply() {
        // While inactive we must stay released regardless of desire; the
        // activation observer reacquires.
        guard isAppActive() else { return }
        setSystemState(desired)
    }

    private func appDidBecomeActive() {
        setSystemState(desired)
    }

    private func appDidResignActive() {
        setSystemState(false)
    }

    /// The single place the OS state flips, so enable/disable stay balanced:
    /// `enabled` tracks exactly one outstanding EnableSecureEventInput.
    private func setSystemState(_ on: Bool) {
        guard enabled != on else { return }
        let err = on ? enableHook() : disableHook()
        guard err == noErr else {
            logger.warning("secure input \(on ? "enable" : "disable", privacy: .public) failed err=\(err, privacy: .public)")
            return
        }
        enabled = on
        logger.info("secure input enabled=\(on, privacy: .public)")
    }
}
