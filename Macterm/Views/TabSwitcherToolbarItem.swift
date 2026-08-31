import SwiftUI

/// Numbered segmented control in the window title bar that mirrors a fixed
/// 5-tab sliding window of the active project's tabs. Each segment shows
/// the tab's 1-based index; Cmd+digit in `Responders.swift` selects by
/// that same index (multi-digit numbers accumulate while Cmd is held).
///
/// The window centers the active tab when at least two tabs sit on either
/// side; otherwise it clamps to the start or end of the workspace. The
/// control itself never scrolls — switching tabs simply replaces the
/// visible segments. With ≤ 5 tabs, every tab is shown.
///
/// When tabs sit off either end of the visible window, the first/last
/// segment is relabelled `…` — a quiet affordance that more tabs exist in
/// that direction. The segment still selects its underlying tab when
/// clicked. Cmd+digit keeps using real tab indices via the keyboard
/// handler in `Responders.swift`, so shortcuts aren't affected.
struct TabSwitcherToolbarItem: View {
    @Environment(AppState.self)
    private var appState

    @AppStorage(Preferences.Keys.tabSwitcherVisibility)
    private var visibilityRaw: String = TabSwitcherVisibility.whenMultiple.rawValue

    /// Width of the detail column, measured by `MainWindow`. The toolbar has
    /// no "hide when clipped" mode — a control that doesn't fit folds into
    /// the overflow (») menu, which is worse than no switcher at all. Below
    /// `minimumDetailWidth` the switcher hides before AppKit would clip it.
    var availableWidth: CGFloat = .infinity

    private static let windowSize = 5
    private static let minimumDetailWidth: CGFloat = 420

    var body: some View {
        let visibility = TabSwitcherVisibility(rawValue: visibilityRaw) ?? .whenMultiple
        if visibility != .hidden,
           availableWidth >= Self.minimumDetailWidth,
           let workspace = activeWorkspace,
           !workspace.tabs.isEmpty,
           visibility == .always || workspace.tabs.count > 1
        {
            let tabs = workspace.tabs
            let activeIndex = tabs.firstIndex(where: { $0.id == workspace.activeTabID }) ?? 0
            let window = slidingWindow(activeIndex: activeIndex, tabCount: tabs.count)
            let windowTabs = Array(tabs[window])
            let labels = windowTabs.indices.map {
                label(offset: $0, window: window, tabCount: tabs.count)
            }

            Picker("Tab", selection: Binding(
                get: { workspace.activeTabID },
                set: { newValue in
                    guard let id = newValue, let projectID = appState.activeProjectID else { return }
                    appState.selectTab(id, projectID: projectID)
                }
            )) {
                ForEach(Array(zip(windowTabs, labels)), id: \.0.id) { tab, label in
                    Text(label)
                        .tag(Optional(tab.id))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            // Rebuild the control whenever the rendered segments change, so
            // its width can never lag its contents by one change.
            //
            // A segmented picker hosted in an `NSToolbarItem` is measured once
            // per view identity, and `fixedSize` is what promotes that
            // measurement to the control's width. Mutating the tab set from
            // `KeyRouter`'s `NSEvent` monitor — Cmd+T, Cmd+W — updates the
            // labels without prompting AppKit to re-measure the item, so the
            // track keeps the *previous* segment count's width: growing clips
            // the last segment, shrinking leaves the track too wide for the
            // segments stretched across it. Paths that happen to end in an
            // independent AppKit layout pass mask it, which is why the same
            // edit through the menu bar or the control socket looks correct
            // and only the keybinds show the bug.
            //
            // Keyed on the labels rather than `windowTabs.count`: a digit
            // flipping to `⋯` changes the ideal width at a constant count.
            .id(labels.joined(separator: "\u{1F}"))
            .help("Cmd+1…\(tabs.count) to switch tabs")
        }
    }

    /// Label for the segment at `offset` inside `window`. Returns `…` for
    /// the leading/trailing segment when more tabs exist off that side;
    /// otherwise the tab's 1-based index.
    private func label(offset: Int, window: Range<Int>, tabCount: Int) -> String {
        let isLeading = offset == 0
        let isTrailing = offset == window.count - 1
        if isLeading, window.lowerBound > 0 { return "⋯" }
        if isTrailing, window.upperBound < tabCount { return "⋯" }
        return "\(window.lowerBound + offset + 1)"
    }

    /// Window of up to `windowSize` indices centered on `activeIndex`,
    /// clamped to `0..<tabCount`. Always returns a non-empty range when
    /// `tabCount > 0`.
    private func slidingWindow(activeIndex: Int, tabCount: Int) -> Range<Int> {
        let size = min(Self.windowSize, tabCount)
        let half = size / 2
        var start = activeIndex - half
        start = max(0, min(start, tabCount - size))
        return start ..< (start + size)
    }

    private var activeWorkspace: Workspace? {
        guard let pid = appState.activeProjectID else { return nil }
        return appState.workspaces[pid]
    }
}
