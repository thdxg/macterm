import Foundation
import Observation

/// One terminal window's own selection state (#345).
///
/// Macterm was single-window, so "which project is showing" lived on `AppState`
/// as a single `activeProjectID`. With several windows that value has to mean
/// two different things at once — what THIS window renders, and what the app
/// as a whole considers frontmost (which drives polling cadence, remote
/// foreground probes, and which project gets its shells warmed).
///
/// They are split rather than duplicated: this type owns the per-window answer,
/// and `AppState.activeProjectID` becomes a mirror of whichever window is key.
/// That keeps every existing "the frontmost project" call site correct as
/// written — there are far more of those than there are genuine selection
/// sites — while the views that render a specific window read this instead.
///
/// Deliberately NOT a place for tab or pane selection yet. `Workspace`
/// activeTabID and `TerminalTab.focusedPaneID` stay shared, so two windows
/// showing the SAME project still share a selected tab. That is a real
/// limitation, and not the case #345 asks for: its motivation is one project
/// per Space, where the windows show different projects and never collide.
@MainActor
@Observable
final class WindowState: Identifiable {
    let id = UUID()

    /// The project this window is showing. Independent per window — that is
    /// the whole point.
    var activeProjectID: UUID?

    /// The tab this window shows for each project it has visited, keyed by
    /// project id.
    ///
    /// Per window because a pane owns exactly one `NSView`, which can live in
    /// one view hierarchy: two windows rendering the same tab fought over
    /// every pane's view and the loser drew nothing. `Workspace.activeTabID`
    /// stays the KEY window's selection — a mirror of this map, the same
    /// shape as `AppState.activeProjectID` — so every "the tab the user is
    /// working in" call site keeps working unchanged, and a window that loses
    /// its tab to another window falls back through
    /// `AppState.displayedTab(for:in:)`.
    var activeTabIDs: [UUID: UUID] = [:]

    /// This window's sidebar width.
    ///
    /// Per window because the restore is ours to do — SwiftUI's own column
    /// autosave writes under a name built from a runtime address and can never
    /// read it back, and `navigationSplitViewColumnWidth`'s `ideal:` is only a
    /// preference AppKit was measured to ignore. Since we restore it by hand
    /// anyway, doing so per window costs nothing extra.
    ///
    /// Seeded from `Preferences.sidebarWidth`, which stays the app-wide
    /// default a NEW window opens at.
    var sidebarWidth: Double

    /// Presentation state that is one-per-window. These used to live on
    /// `AppState`, which was the same thing with one window; with several,
    /// every `MainWindow` rendered them, so ⌘K raised a palette in every
    /// window, the New Remote Project sheet presented on all of them, and
    /// toggling one sidebar toggled every sidebar. `AppState` keeps mirrors
    /// of the key window's copy for the app-wide code paths (hotkeys, palette
    /// commands, the CLI) that mean "the window the user is in".
    var sidebarVisible = true
    var isCommandPaletteVisible = false
    var isNewRemoteProjectSheetPresented = false

    init(activeProjectID: UUID? = nil, sidebarWidth: Double? = nil) {
        self.activeProjectID = activeProjectID
        self.sidebarWidth = sidebarWidth ?? Preferences.shared.sidebarWidth
    }
}
