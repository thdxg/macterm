import Foundation

/// What a tab row's status badge should draw, given the tab's execution state
/// and whether an AI agent holds its foreground.
///
/// A pure function rather than a condition inside the glyph's `body`: the rule
/// has three inputs and two of them are user preferences, which is exactly the
/// shape that rots silently when it lives in a view.
enum TabStatusPolicy {
    enum Badge: Equatable {
        /// A spinner, replacing the tab's icon while a command runs.
        case spinner
        /// The tab's normal icon plus the finished dot.
        case finishedDot
        /// The tab's normal icon, unbadged.
        case none
    }

    /// `hideSpinnerOnAgentTabs` (issue #225) exists because agent CLIs draw
    /// their OWN spinner in the tab title, so ours is duplicate information
    /// covering the one thing the user wants to see there — the agent's logo.
    /// It deliberately suppresses only the spinner: the finished dot is what
    /// tells the user which agent tabs have replies they haven't read, which
    /// is the whole reason they leave the indicator on.
    static func badge(
        state: TerminalExecutionState,
        hasAgent: Bool,
        indicatorEnabled: Bool,
        hideSpinnerOnAgentTabs: Bool
    ) -> Badge {
        guard indicatorEnabled else { return .none }
        switch state {
        case .running:
            return hasAgent && hideSpinnerOnAgentTabs ? .none : .spinner
        case .done:
            return .finishedDot
        case .idle:
            return .none
        }
    }
}
