import AppIntents

/// Every way an intent can refuse. Mirrors `ControlError`'s job for the CLI —
/// a typed failure with a message a person can act on — but in the shape
/// Shortcuts renders: `CustomLocalizedStringResourceConvertible` is what puts
/// the text in the shortcut's own error banner instead of a generic
/// "the action failed".
///
/// Like the CLI's close verbs, an intent that would destroy work returns
/// `.busy` rather than staging a confirmation dialog: a shortcut can run with
/// nobody watching, and a modal nobody answers hangs the whole automation.
enum MactermIntentError: Error, CustomLocalizedStringResourceConvertible {
    /// `Preferences.shortcutsAccess` is `deny`, or the user answered the ask.
    case accessDenied
    /// The app never became ready — no state objects within the deadline.
    case appUnavailable
    /// The entity names something that no longer exists (a closed tab, a pane
    /// whose session ended, a removed project).
    case notFound
    /// The pane exists but has never had a terminal, so there is nothing to
    /// type into or read from. Same contract as the CLI's `no_surface`.
    case noSurface
    /// Closing would end a running program.
    case busy
    /// The input didn't parse (an unknown key chord, an empty command).
    case badInput(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .accessDenied:
            "\(appDisplayName) doesn't allow Shortcuts. Change this in \(appDisplayName) → Settings → General → Shortcuts."
        case .appUnavailable:
            "\(appDisplayName) isn't ready yet."
        case .notFound:
            "That no longer exists in \(appDisplayName)."
        case .noSurface:
            "That pane's terminal isn't live yet. Select its tab once, then try again."
        case .busy:
            "A pane there has a running program. Close it in \(appDisplayName) instead."
        case let .badInput(detail):
            "\(detail)"
        }
    }
}
