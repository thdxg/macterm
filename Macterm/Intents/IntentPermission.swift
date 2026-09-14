import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "IntentPermission")

/// Whether Shortcuts, Spotlight and the `shortcuts` CLI may drive this app
/// through its App Intents: the user's ghostty `macos-shortcuts` key, read
/// live off the loaded config (`GhosttyApp.shortcutsAccess`) with no Settings
/// UI of its own. Ghostty defines the key with the same three values and the
/// same `ask` default, and Macterm's intents are the same kind of surface
/// (create terminals, type into shells), so it is the same setting — the
/// one place Macterm reads it differently is that `ask` remembers the answer
/// for the run only (see `IntentPermissionGate`).
///
/// The raw values are ghostty's own `MacShortcuts` tag names — exactly what
/// `ghostty_config_get` hands back for the key — so they are a wire contract
/// with libghostty, not names of ours.
enum ShortcutsAccess: String, CaseIterable, Identifiable {
    /// Confirm with an alert the first time an intent runs in a launch, then
    /// remember that answer for the rest of the run.
    case ask
    /// Never confirm.
    case allow
    /// Refuse every intent with an error that says how to change it.
    case deny

    static let key = "macos-shortcuts"

    /// An unset, empty, unreadable, or unrecognized value means `ask` —
    /// ghostty's default, and the conservative one: a key a newer ghostty grew
    /// a fourth case for degrades to a prompt rather than to a silent grant.
    static func resolve(configValue: String?) -> ShortcutsAccess {
        guard let raw = configValue?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return .ask
        }
        return ShortcutsAccess(rawValue: raw.lowercased()) ?? .ask
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ask: "Ask"
        case .allow: "Allow"
        case .deny: "Deny"
        }
    }
}

/// The pure policy half of the permission gate: given the preference, whatever
/// the user already answered this run, and whether this is a harness run, what
/// should happen next. Kept apart from `IntentPermissionGate` so it can be
/// tested without an alert or a UserDefaults domain.
enum IntentPermission {
    enum Decision: Equatable {
        /// Run the intent.
        case allow
        /// Fail the intent.
        case deny
        /// Put the alert up, then remember the answer.
        case ask
    }

    /// `recorded` is the answer already given this launch, if any.
    ///
    /// A harness run never asks: the benchmark and e2e harnesses hand the app a
    /// throwaway `$HOME` and data dir and drive it with nobody at the keyboard,
    /// so a modal alert would block the launch run loop the way Sparkle's
    /// failed-start alert used to — the same reason `BenchmarkControl` skips the
    /// notification-permission prompt. It resolves to `.allow` rather than
    /// `.deny` because a hermetic instance is the harness's own to drive, and a
    /// silent refusal would look like a broken intent rather than a policy.
    /// An explicit `.deny` still denies, since that is a decision, not a prompt.
    static func decide(
        access: ShortcutsAccess,
        recorded: Bool?,
        isHarnessRun: Bool
    ) -> Decision {
        switch access {
        case .allow: return .allow
        case .deny: return .deny
        case .ask:
            if let recorded { return recorded ? .allow : .deny }
            return isHarnessRun ? .allow : .ask
        }
    }
}

/// The effectful half: puts the alert up and remembers the answer for the rest
/// of the launch.
///
/// The grant is deliberately per-run and in memory. Persisting it would make a
/// single "Allow" a standing grant for every future launch, which is what
/// `.allow` is for — the point of `.ask` is that the user is asked again the
/// next time the app starts.
@MainActor
final class IntentPermissionGate {
    static let shared = IntentPermissionGate()

    /// The answer given this launch, nil until the first ask.
    private var recorded: Bool?

    /// Injectable so tests drive the policy without AppKit. Returns whether the
    /// user allowed it.
    var presentAlert: @MainActor () -> Bool = IntentPermissionGate.runModalAlert

    /// Where the setting comes from — injectable for the same reason. Read on
    /// every authorize rather than captured, so a config reload that flips
    /// `macos-shortcuts` takes effect on the next intent with no restart.
    /// Tests override this instead of loading a ghostty config.
    var access: @MainActor () -> ShortcutsAccess = { GhosttyApp.shared.shortcutsAccess }

    private init() {}

    /// Throws `MactermIntentError.accessDenied` unless the intent may run.
    func authorize() throws {
        let access = access()
        switch IntentPermission.decide(
            access: access,
            recorded: recorded,
            isHarnessRun: BenchmarkControl.isEnabled
        ) {
        case .allow:
            return
        case .deny:
            logger.info("intent refused: access is \(access.rawValue, privacy: .public)")
            throw MactermIntentError.accessDenied
        case .ask:
            let allowed = presentAlert()
            recorded = allowed
            logger.info("intent permission asked: allowed=\(allowed, privacy: .public)")
            if !allowed { throw MactermIntentError.accessDenied }
        }
    }

    /// Forget the recorded answer and the injected seams — tests only;
    /// production records once per process and never clears.
    func resetForTesting() {
        recorded = nil
        presentAlert = IntentPermissionGate.runModalAlert
        access = { GhosttyApp.shared.shortcutsAccess }
    }

    private static func runModalAlert() -> Bool {
        // The intent runs on the main actor, so this is a plain modal — the
        // same shape as `QuitConfirmation.runModal`.
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Allow Shortcuts to control \(appDisplayName)?"
        alert.informativeText = "A shortcut wants to run an action in \(appDisplayName). "
            + "It can create projects and tabs, and type into your terminals."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
