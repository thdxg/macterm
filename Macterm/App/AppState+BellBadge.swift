import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "BellBadge")

/// The Dock badge for unacknowledged bells — `bell-features = attention`'s
/// second half (the first, the dock bounce, is `GhosttyCallbacks.ringBell`).
///
/// The badge is never written from the ring itself. It is DERIVED from the
/// panes' `hasUnacknowledgedBell` flags by `syncDockBadge`, which runs when a
/// bell flips, when the config reloads (the feature may have come or gone),
/// and at every structural save (a closed tab leaves the count). That is what
/// lets a config reload that drops `attention` clear a badge that is already
/// up, with no code path that knows about "clearing" at all.
///
/// What counts as acknowledged follows Macterm's existing verdict for a
/// finished command rather than ghostty's own: ghostty flags the surface
/// unconditionally and clears it on the next keypress or focus gain, so a
/// bell in the window you are typing in badges the Dock until you type. Here
/// a bell in the active tab of the active app is seen the moment it rings —
/// `acknowledgeFinishedCommandIfActive` already says looking at the active
/// tab acknowledges its panes, and the badge should not disagree with the
/// sidebar about what the user has seen. Everything else clears the same way
/// the completion dot does: selecting the tab, focusing or interacting with
/// the pane, or bringing the app back to the front while the tab is showing.
extension AppState {
    /// A pane's bell flipped. Acknowledge it right away if the user is looking
    /// at its tab, and only then re-derive — the acknowledgment's own flip
    /// re-enters here with the flag already down, so the badge is written once
    /// and never flashes a count for a bell that was seen.
    func paneBellStateDidChange(paneID: UUID) {
        if isAppActive(),
           let projectID = activeProjectID,
           let tab = workspaces[projectID]?.activeTab,
           tab.splitRoot.findPane(id: paneID) != nil
        {
            tab.acknowledgeBell()
        }
        syncDockBadge()
    }

    /// The app came to the front: whatever tab it shows is now being looked
    /// at. Mirrors ghostty, where the key window's focused surface drops its
    /// bell on `windowDidBecomeKey`; Macterm's unit is the tab.
    func acknowledgeBellsInActiveTab() {
        guard let projectID = activeProjectID,
              let tab = workspaces[projectID]?.activeTab
        else { return }
        tab.acknowledgeBell()
    }

    /// Re-derive the badge from every tab in every workspace (the pinned
    /// sentinel included — its tabs ring like any other) and write it only
    /// when it changed. Mirror (shadow) tabs are not in `workspaces`, so a
    /// tab shown in two windows counts once.
    func syncDockBadge() {
        let features = bellFeatures()
        let count = BellBadge.tabCount(workspaces.values.flatMap(\.tabs))
        let label = BellBadge.label(bellTabCount: count, features: features)
        guard label != dockBadgeLabel else { return }
        let text = label ?? "none"
        logger.debug("dock badge: \(text, privacy: .public) (\(count, privacy: .public) ringing tabs)")
        dockBadgeLabel = label
        dockBadgeWriter(label)
    }
}
