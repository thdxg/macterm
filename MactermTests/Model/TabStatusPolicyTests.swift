import Foundation
@testable import Macterm
import Testing

/// #225: the spinner can be suppressed on agent tabs without touching the
/// finished dot. These pin the asymmetry, which is the whole point of the
/// preference — an implementation that hid both would look correct while
/// removing the signal the requester actually relies on.
@MainActor
struct TabStatusPolicyTests {
    @Test
    func a_running_tab_shows_the_spinner_by_default() {
        #expect(TabStatusPolicy.badge(
            state: .running,
            hasAgent: false,
            indicatorEnabled: true,
            hideSpinnerOnAgentTabs: false
        ) == .spinner)
    }

    @Test
    func an_agent_tab_keeps_its_spinner_until_the_preference_is_on() {
        #expect(TabStatusPolicy.badge(
            state: .running,
            hasAgent: true,
            indicatorEnabled: true,
            hideSpinnerOnAgentTabs: false
        ) == .spinner)
    }

    @Test
    func the_preference_suppresses_the_spinner_only_on_agent_tabs() {
        #expect(TabStatusPolicy.badge(
            state: .running,
            hasAgent: true,
            indicatorEnabled: true,
            hideSpinnerOnAgentTabs: true
        ) == .none)
        // A plain command still spins: the agent's own spinner is what makes
        // ours redundant, and a shell has none.
        #expect(TabStatusPolicy.badge(
            state: .running,
            hasAgent: false,
            indicatorEnabled: true,
            hideSpinnerOnAgentTabs: true
        ) == .spinner)
    }

    /// The requirement the preference must NOT break: the dot is how the user
    /// spots agent tabs with unread replies.
    @Test
    func the_finished_dot_survives_the_preference() {
        #expect(TabStatusPolicy.badge(
            state: .done,
            hasAgent: true,
            indicatorEnabled: true,
            hideSpinnerOnAgentTabs: true
        ) == .finishedDot)
    }

    @Test
    func the_indicator_switch_still_wins_over_everything() {
        for state in [TerminalExecutionState.idle, .running, .done] {
            #expect(TabStatusPolicy.badge(
                state: state,
                hasAgent: true,
                indicatorEnabled: false,
                hideSpinnerOnAgentTabs: false
            ) == .none)
        }
    }

    @Test
    func an_idle_tab_carries_no_badge() {
        #expect(TabStatusPolicy.badge(
            state: .idle,
            hasAgent: false,
            indicatorEnabled: true,
            hideSpinnerOnAgentTabs: false
        ) == .none)
    }
}
