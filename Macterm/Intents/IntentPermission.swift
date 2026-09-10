import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "IntentPermission")

/// Whether Shortcuts, Spotlight and the `shortcuts` CLI may drive this app
/// through its App Intents.
///
/// Mirrors Ghostty's `macos-shortcuts` config key, but lives in `Preferences`
/// rather than the ghostty config pipeline: the rule is that ghostty keys carry
/// libghostty-shaped settings (theme, font, palette, shell integration) and
/// everything about Macterm's own UI and automation surface is a `Preferences`
/// value. An intent can create projects, close tabs and type into shells —
/// none of which libghostty knows anything about — so a ghostty key would be
/// asking the terminal core's config to gate a Macterm feature it has no other
/// stake in, and would break the "the user is the source of truth for every
/// ghostty setting" contract by adding a key ghostty itself doesn't define.
///
/// The raw values are persisted, so renaming a case is a stored-preference
/// migration; an unrecognized stored value falls back to `.ask`.
enum ShortcutsAccess: String, CaseIterable, Identifiable {
    /// Confirm with an alert the first time an intent runs in a launch, then
    /// remember that answer for the rest of the run.
    case ask
    /// Never confirm.
    case allow
    /// Refuse every intent with an error that says how to change it.
    case deny

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

    /// Where the preference comes from — injectable for the same reason. Read
    /// on every authorize rather than captured, so flipping the setting takes
    /// effect on the next intent with no restart. Tests override this instead
    /// of writing `Preferences.shared`, which swift-testing's parallel suites
    /// share.
    var access: @MainActor () -> ShortcutsAccess = { Preferences.shared.shortcutsAccess }

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
        access = { Preferences.shared.shortcutsAccess }
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
