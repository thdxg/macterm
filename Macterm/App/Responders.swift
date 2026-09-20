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

        // Passthrough gate, ahead of every branch: a binding the user flagged
        // yields to the program running in the focused pane (see
        // KeybindPassthrough). Returning `.passThrough` is only half the job —
        // `isAppShortcut` would otherwise swallow the chord once the event
        // reaches the surface's `keyDown`, so it consults the same policy.
        if KeybindPassthrough.yields(event: event, pane: state.tab.focusedPane) {
            return .passThrough
        }

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
/// cycling, project navigation, new tab, new project, Cmd+digit tab
/// selection, etc. Runs after the palette and quick-terminal responders.
@MainActor
final class MainAppResponder: KeyResponder {
    private let appState: AppState
    private let projectStore: ProjectStore
    weak var mainWindow: NSWindow?
    private var tabIndexChord = TabIndexChord()

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

        // Everything below acts on the main terminal window's workspace.
        // When a different window is key — Settings, an alert sheet — none of
        // it may fire: Cmd+W would close a terminal tab behind the window the
        // user is actually looking at. Close shortcuts retarget to the key
        // window (the macOS convention: Cmd+W closes the key window). Pass-
        // through alone can't provide that — the system File > Close item is
        // replaced by our "Close Pane" (CommandGroup(replacing: .saveItem)),
        // so the menu bar would re-route Cmd+W right back to the tab. The
        // quick-terminal panel is exempt: QuickTerminalResponder has already
        // claimed its slice, and the app-wide keys that fall through (project
        // nav, new tab, …) intentionally keep working while the panel is up.
        //
        // This branch requires a KNOWN `mainWindow`: it only means "a DIFFERENT
        // window is key" when we know which one is the terminal window. At
        // launch `mainWindow` can still be briefly nil (its `didBecomeMain`
        // lands after responders install when the app is launched by direct
        // exec rather than LaunchServices), and a nil pointer is `!==` every
        // real window —
        // so without the `let main` guard, the terminal window itself would be
        // treated as "different", making Cmd+W close the window and Cmd+D
        // pass through until the first `didBecomeMain`. When `mainWindow` is
        // unknown, fall through to normal handling (the terminal window is the
        // only window that can be key that early).
        // "A different window" means a NON-TERMINAL window (Settings, an alert
        // sheet) — not "not the one cached window". With several terminal
        // windows open (#345) every one of them must take these keys, acting
        // on whichever is focused; gating on `mainWindow` identity would leave
        // every window but the first with a dead keymap. `isTerminalWindow` is
        // an exact registry rather than the `isTerminalWindowCandidate`
        // heuristic, which also matches Settings.
        //
        // The `mainWindow` guard survives for its original reason: before the
        // first window registers, `isTerminalWindow` answers false for every
        // window, and without it the terminal window itself would be treated
        // as "different" — making Cmd+W close the window and Cmd+D pass
        // through until registration lands.
        if mainWindow != nil, let keyWindow = NSApp.keyWindow,
           !(appState.appDelegate?.isTerminalWindow(keyWindow) ?? false),
           !(keyWindow is QuickTerminalPanel)
        {
            if HotkeyRegistry.matches(event, action: .closePane)
                || HotkeyRegistry.matches(event, action: .closeWindow)
            {
                keyWindow.performClose(nil)
                return .handled
            }
            return .passThrough
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Passthrough gate, ahead of every action branch: a binding the user
        // flagged yields to the program running in the focused pane (see
        // KeybindPassthrough). Placed AFTER the different-window branch above —
        // when another window is key the terminal isn't receiving keys at all,
        // so that branch's Cmd+W retarget must keep working regardless of what
        // the terminal's focused pane is running.
        if let projectID = appState.activeProjectID,
           KeybindPassthrough.yields(event: event, pane: appState.focusedPane(for: projectID))
        {
            return .passThrough
        }

        // Every configurable binding runs the `AppCommand` that owns it,
        // through `AppCommand.action(in:)` — the single source of truth shared
        // with the palette, the menu bar, the Dock menu and App Intents — so a
        // guard tightened there cannot be missed here. A nil action (no active
        // project, nothing to separate, no applicable layout file, …) falls
        // through as `.passThrough`, exactly as the palette hides the row.
        //
        // `HotkeyAction.allCases` order breaks ties when a user binds two
        // actions to one chord: the global tab pair precedes the in-project
        // pair, so the global one wins, as it always has. The quick-terminal
        // toggle is here too (the same chord is a Carbon global hot key for
        // when Macterm isn't active; this covers the in-app case).
        //
        // Two bindings were once answered here by hand and deliberately are
        // not any more. New Window: a "re-front the single window" fallback
        // from before multi-window answered `.handled` and so swallowed the
        // chord before the File menu's item — the only thing that opened a
        // window — ever saw it. Close Window: `mainWindow?.orderOut(nil)` HID
        // the first window whatever window the user was in, and a hidden
        // window stays registered and persisted, which is how quitting with
        // one window on screen brought two back. Both now run under the one
        // open/close policy in `AppCommandActions`.
        if let action = HotkeyAction.allCases.first(where: { HotkeyRegistry.matches(event, action: $0) }) {
            let ctx = AppCommandContext(appState: appState, projectStore: projectStore)
            guard let run = action.appCommand.action(in: ctx) else { return .passThrough }
            run()
            return .handled
        }

        // Cmd+digit tab selection. Must check after the configurable hotkeys
        // so user bindings take precedence over digits.
        //
        // Digits accumulate into a multi-digit number while Command stays
        // down (see TabIndexChord), so a workspace with more than nine tabs
        // is fully reachable. Every digit 1-9 is still swallowed even when it
        // addresses nothing, matching the old single-digit binding; a `0` that
        // isn't a valid continuation passes through, since on its own it is
        // ghostty's reset-font-size chord, not ours.
        if flags == .command {
            let key = (event.charactersIgnoringModifiers ?? "").lowercased()
            if key.count == 1, let digit = Int(key), (0 ... 9).contains(digit),
               let projectID = appState.activeProjectID
            {
                // Auto-repeat must not accumulate: holding Cmd+1 down is one
                // request for tab 1, not a walk through 1, 11, 111.
                guard !event.isARepeat else { return .handled }
                let tabCount = appState.selectableTabCount(projectID: projectID)
                if let number = tabIndexChord.press(digit: digit, tabCount: tabCount) {
                    appState.selectTabByIndex(number - 1, projectID: projectID)
                    return .handled
                }
                return digit == 0 ? .passThrough : .handled
            }
        }

        return .passThrough
    }

    /// Ends an in-flight Cmd+digit run, so the next digit starts a fresh
    /// number instead of extending the last one. Driven by the flags monitor
    /// on Command release.
    func endTabIndexChord() {
        tabIndexChord.reset()
    }
}
