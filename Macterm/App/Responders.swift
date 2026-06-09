import AppKit

// The main `handleKeyEvent` used to be a 140-line cascade of if-statements in
// MactermApp.swift. These responders own focused slices of that logic and get
// ordered by the KeyRouter so disposition is explicit instead of implicit.

/// Toggles the unified command palette on Cmd+P / Cmd+Shift+P. When the
/// palette is visible, passes other keys through to SwiftUI's own key
/// handlers (arrow navigation, escape, etc.).
@MainActor
final class PaletteResponder: KeyResponder {
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func handle(_ event: NSEvent) -> KeyDisposition {
        if HotkeyRegistry.matches(event, action: .toggleCommandPalette) {
            appState.isCommandPaletteVisible.toggle()
            return .handled
        }
        // While the palette is visible, SwiftUI owns arrow / escape / etc.
        return .passThrough
    }
}

/// Handles all hotkeys while the quick terminal is visible. Registered before
/// the main-app responder so split/close/focus route to the quick terminal
/// instead of the main window when the panel is up.
@MainActor
final class QuickTerminalResponder: KeyResponder {
    private static let focusActions: [(HotkeyAction, PaneFocusDirection)] = [
        (.focusPaneLeft, .left),
        (.focusPaneDown, .down),
        (.focusPaneUp, .up),
        (.focusPaneRight, .right),
    ]

    private static let resizeActions: [(HotkeyAction, PaneFocusDirection)] = [
        (.resizePaneLeft, .left),
        (.resizePaneDown, .down),
        (.resizePaneUp, .up),
        (.resizePaneRight, .right),
    ]

    func handle(_ event: NSEvent) -> KeyDisposition {
        let qt = QuickTerminalService.shared
        guard qt.isVisible else { return .passThrough }
        let state = qt.splitState

        // Quick-terminal toggle keystroke arrived while Macterm itself is
        // active. The same shortcut is also registered as a Carbon global
        // hot key (see QuickTerminalService.registerHotKey) for when other
        // apps are frontmost.
        if HotkeyRegistry.matches(event, action: .toggleQuickTerminal) {
            NotificationCenter.default.post(name: .toggleQuickTerminal, object: nil)
            return .handled
        }

        if HotkeyRegistry.matches(event, action: .splitRight) {
            guard let paneID = state.focusedPaneID else { return .passThrough }
            state.split(paneID: paneID, direction: .horizontal)
            return .handled
        }
        if HotkeyRegistry.matches(event, action: .splitDown) {
            guard let paneID = state.focusedPaneID else { return .passThrough }
            state.split(paneID: paneID, direction: .vertical)
            return .handled
        }
        if HotkeyRegistry.matches(event, action: .splitAuto) {
            guard let paneID = state.focusedPaneID else { return .passThrough }
            state.autoSplit(paneID: paneID)
            return .handled
        }
        if HotkeyRegistry.matches(event, action: .closePane) {
            guard let paneID = state.focusedPaneID else { return .passThrough }
            state.requestClosePane(paneID)
            return .handled
        }
        if HotkeyRegistry.matches(event, action: .zoomPane) {
            guard let paneID = state.focusedPaneID else { return .passThrough }
            state.tab.toggleZoom(paneID: paneID)
            return .handled
        }
        if let (_, dir) = Self.focusActions.first(where: { HotkeyRegistry.matches(event, action: $0.0) }) {
            guard let focusedID = state.focusedPaneID else { return .passThrough }
            if let bestID = state.splitRoot.nearestPane(from: focusedID, direction: dir) {
                state.focusPane(bestID)
            }
            return .handled
        }
        if let (_, dir) = Self.resizeActions.first(where: { HotkeyRegistry.matches(event, action: $0.0) }) {
            state.resize(dir)
            return .handled
        }

        return .passThrough
    }
}

/// App-level hotkeys for the main window: split, close, focus, resize, tab
/// cycling, project navigation, new tab, new project, Cmd+1-9 tab selection,
/// etc. Runs after the palette and quick-terminal responders.
@MainActor
final class MainAppResponder: KeyResponder {
    private let appState: AppState
    private let projectStore: ProjectStore
    weak var mainWindow: NSWindow?

    private static let focusActions: [(HotkeyAction, PaneFocusDirection)] = [
        (.focusPaneLeft, .left),
        (.focusPaneDown, .down),
        (.focusPaneUp, .up),
        (.focusPaneRight, .right),
    ]

    private static let resizeActions: [(HotkeyAction, PaneFocusDirection)] = [
        (.resizePaneLeft, .left),
        (.resizePaneDown, .down),
        (.resizePaneUp, .up),
        (.resizePaneRight, .right),
    ]

    init(appState: AppState, projectStore: ProjectStore) {
        self.appState = appState
        self.projectStore = projectStore
    }

    func handle(_ event: NSEvent) -> KeyDisposition {
        // Hotkey picker in Settings captures keystrokes — pass through so the
        // user's next keypress reaches the picker instead of triggering actions.
        if HotkeyCaptureState.shared.isCapturing { return .passThrough }

        // When the command palette is visible, let SwiftUI's TextField /
        // onKeyPress handlers own the keyboard. Otherwise typing "New Tab"
        // into the palette would fire Cmd+T's New Tab action.
        if appState.isCommandPaletteVisible { return .passThrough }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Quick-terminal toggle. The same shortcut is also a Carbon global
        // hot key (see QuickTerminalService) for when Macterm isn't active;
        // this branch covers the in-app case.
        if HotkeyRegistry.matches(event, action: .toggleQuickTerminal) {
            NotificationCenter.default.post(name: .toggleQuickTerminal, object: nil)
            return .handled
        }

        if HotkeyRegistry.matches(event, action: .recentTab) {
            guard let projectID = appState.activeProjectID else { return .passThrough }
            appState.cycleRecentTab(projectID: projectID)
            return .handled
        }

        // Block Cmd+N from opening a second window.
        if flags == .command, (event.charactersIgnoringModifiers ?? "").lowercased() == "n" {
            mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return .handled
        }

        if HotkeyRegistry.matches(event, action: .newTab) {
            guard let projectID = appState.activeProjectID else { return .passThrough }
            appState.createTab(projectID: projectID, projects: projectStore.projects)
            return .handled
        }

        if HotkeyRegistry.matches(event, action: .closePane) {
            guard let projectID = appState.activeProjectID,
                  let pane = appState.focusedPane(for: projectID)
            else { return .passThrough }
            appState.requestClosePane(pane.id, projectID: projectID)
            return .handled
        }

        if HotkeyRegistry.matches(event, action: .splitRight) {
            guard let projectID = appState.activeProjectID else { return .passThrough }
            appState.splitPane(direction: .horizontal, projectID: projectID)
            return .handled
        }

        if HotkeyRegistry.matches(event, action: .splitDown) {
            guard let projectID = appState.activeProjectID else { return .passThrough }
            appState.splitPane(direction: .vertical, projectID: projectID)
            return .handled
        }

        if HotkeyRegistry.matches(event, action: .splitAuto) {
            guard let projectID = appState.activeProjectID else { return .passThrough }
            appState.autoSplitPane(projectID: projectID)
            return .handled
        }

        if HotkeyRegistry.matches(event, action: .zoomPane) {
            guard let projectID = appState.activeProjectID else { return .passThrough }
            appState.toggleZoom(projectID: projectID)
            return .handled
        }

        if HotkeyRegistry.matches(event, action: .toggleSidebar) {
            appState.sidebarVisible.toggle()
            return .handled
        }

        if HotkeyRegistry.matches(event, action: .nextProject) {
            appState.selectNextProject(projects: projectStore.projects)
            return .handled
        }
        if HotkeyRegistry.matches(event, action: .previousProject) {
            appState.selectPreviousProject(projects: projectStore.projects)
            return .handled
        }
        if HotkeyRegistry.matches(event, action: .nextGlobalTab) {
            appState.selectGlobalTab(.next, projects: projectStore.projects)
            return .handled
        }
        if HotkeyRegistry.matches(event, action: .previousGlobalTab) {
            appState.selectGlobalTab(.previous, projects: projectStore.projects)
            return .handled
        }

        if let (_, dir) = Self.focusActions.first(where: { HotkeyRegistry.matches(event, action: $0.0) }) {
            guard let projectID = appState.activeProjectID else { return .passThrough }
            appState.focusPaneInDirection(dir, projectID: projectID)
            return .handled
        }

        if let (_, dir) = Self.resizeActions.first(where: { HotkeyRegistry.matches(event, action: $0.0) }) {
            guard let projectID = appState.activeProjectID else { return .passThrough }
            appState.resizePane(dir, projectID: projectID)
            return .handled
        }

        if HotkeyRegistry.matches(event, action: .closeWindow) {
            mainWindow?.orderOut(nil)
            return .handled
        }

        if HotkeyRegistry.matches(event, action: .openProject) {
            _ = appState.openProject(store: projectStore)
            return .handled
        }

        if HotkeyRegistry.matches(event, action: .reloadGhosttyConfig) {
            GhosttyApp.shared.reloadAndReport()
            return .handled
        }

        // Rename routes through AppCommand.action(in:) — the single source of
        // truth shared with the palette and menu bar — so the three paths can't
        // drift. The action defers begin-editing a tick (see AppCommandActions)
        // so the sidebar row's TextField exists before it takes first responder.
        for action in [HotkeyAction.renameTab, .renameProject] {
            guard HotkeyRegistry.matches(event, action: action),
                  let command = AppCommand.allCases.first(where: { $0.hotkeyAction == action })
            else { continue }
            let ctx = AppCommandContext(appState: appState, projectStore: projectStore)
            guard let run = command.action(in: ctx) else { return .passThrough }
            run()
            return .handled
        }

        // Cmd+1-9 tab selection. Must check after the configurable hotkeys
        // so user bindings take precedence over digits.
        if flags == .command {
            let key = (event.charactersIgnoringModifiers ?? "").lowercased()
            if let idx = Int(key), (1 ... 9).contains(idx),
               let projectID = appState.activeProjectID
            {
                appState.selectTabByIndex(idx - 1, projectID: projectID)
                return .handled
            }
        }

        return .passThrough
    }
}
