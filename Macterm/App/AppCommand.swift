import Foundation

/// Single source of truth for every user-invokable action — both palette
/// commands and keyboard-bindable ones. Exposes a title-cased `title` (macOS
/// menu convention) and a `category` so the palette and Settings can render the same list without
/// duplicated strings. The optional `hotkeyAction` link says whether a
/// command is rebindable; palette-only commands (like renaming the current
/// project) return nil.
enum AppCommand: String, CaseIterable, Identifiable {
    // Palettes — the command palette's own chord and every screen of it
    // (`PaletteScopeID`), listed first: they are places to go, and with
    // custom palettes they are the user's own entries.
    case toggleCommandPalette
    case passwordManager
    case files
    // Tabs
    case newTab
    case closePane
    case closeTab
    case renameTab
    case nextTab
    case previousTab
    case nextTabInProject
    case previousTabInProject
    case recentTab
    case moveTabUp
    case moveTabDown
    case separateAllPanes
    case pinTab
    case unpinTab
    // Panes
    case splitRight
    case splitDown
    case splitAuto
    case separateCurrentPane
    case zoomPane
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case nextPane
    case previousPane
    case resizeLeft
    case resizeRight
    case resizeUp
    case resizeDown
    case movePaneLeft
    case movePaneRight
    case movePaneUp
    case movePaneDown
    case copySessionID
    case capturePane
    case copyMode
    case readOnlyMode
    case explainOutput
    case autofillPassword
    // Projects
    case openProject
    case newRemoteProject
    case renameProject
    case unloadProject
    case removeProject
    case replaceProjectPathWithCurrentDir
    case applyLayout
    case saveLayout
    case nextProject
    case previousProject
    // Window
    case toggleSidebar
    case toggleToolbar
    case newWindow
    case newDesktopWidget
    case closeWindow
    case settings
    case reloadGhosttyConfig
    case openMactermConfig
    case toggleQuickTerminal
    case checkForUpdate
    case capturePaletteScreenshot

    var id: String { rawValue }

    /// The title in the user's language. Every place that shows a command —
    /// the palette, the menu bar, Keymaps, the Dock menu — reads this.
    var title: String { String(localized: titleResource) }

    /// The title in English, the language the source is written in. The
    /// palette also matches a query against it, so a command can be found
    /// by its English name under any language.
    var englishTitle: String { Self.englishTitles[self] ?? rawValue }

    /// What a search matches besides `title`: the English title, when the
    /// shown title is a translation.
    var searchAliases: [String] {
        englishTitle == title ? [] : [englishTitle]
    }

    /// Resolved one time: the English text never changes while the app runs,
    /// and the palette and Keymaps read it on each keystroke.
    private static let englishTitles = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0, String(english: $0.titleResource)) }
    )

    private var titleResource: LocalizedStringResource {
        switch self {
        case .newTab: "New Tab"
        case .closePane: "Close Pane"
        case .closeTab: "Close Tab"
        case .renameTab: "Rename Current Tab"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .nextTabInProject: "Next Tab in Project"
        case .previousTabInProject: "Previous Tab in Project"
        case .recentTab: "Recent Tab"
        case .moveTabUp: "Move Tab Up"
        case .moveTabDown: "Move Tab Down"
        case .separateAllPanes: "Separate All Panes"
        case .pinTab: "Pin Tab"
        case .unpinTab: "Unpin Tab"
        case .separateCurrentPane: "Separate Current Pane"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .splitAuto: "Split Automatically"
        case .zoomPane: "Zoom Pane"
        case .focusLeft: "Focus Left"
        case .focusRight: "Focus Right"
        case .focusUp: "Focus Up"
        case .focusDown: "Focus Down"
        case .nextPane: "Next Pane"
        case .previousPane: "Previous Pane"
        case .resizeLeft: "Resize Pane Left"
        case .resizeRight: "Resize Pane Right"
        case .resizeUp: "Resize Pane Up"
        case .resizeDown: "Resize Pane Down"
        case .movePaneLeft: "Move Pane Left"
        case .movePaneRight: "Move Pane Right"
        case .movePaneUp: "Move Pane Up"
        case .movePaneDown: "Move Pane Down"
        case .copySessionID: "Copy Session ID"
        case .capturePane: "Capture Pane"
        case .copyMode: "Copy Mode"
        case .readOnlyMode: "Read-Only Mode"
        case .explainOutput: "Explain Output"
        case .autofillPassword: "Autofill Password"
        case .passwordManager: "Password Manager"
        case .openProject: "Open Project"
        case .newRemoteProject: "New Remote Project"
        case .renameProject: "Rename Current Project"
        case .unloadProject: "Unload Current Project"
        case .removeProject: "Remove Current Project"
        case .replaceProjectPathWithCurrentDir: "Replace Project Path with Current Directory"
        case .files: "Files"
        case .applyLayout: "Apply Layout"
        case .saveLayout: "Save Layout"
        case .nextProject: "Next Project"
        case .previousProject: "Previous Project"
        case .toggleSidebar: "Toggle Sidebar"
        case .toggleToolbar: "Toggle Toolbar"
        case .newWindow: "New Window"
        case .newDesktopWidget: "New Desktop Widget"
        case .closeWindow: "Close Window"
        case .toggleCommandPalette: "Command Palette"
        case .settings: "Settings"
        case .reloadGhosttyConfig: "Reload Ghostty Config"
        case .openMactermConfig: "Open Macterm Config"
        case .toggleQuickTerminal: "Toggle Quick Terminal"
        case .checkForUpdate: "Check for Update"
        case .capturePaletteScreenshot: "Capture Palette"
        }
    }

    var category: Category {
        switch self {
        case .toggleCommandPalette,
             .passwordManager,
             .files: .palettes
        case .newTab,
             .closePane,
             .closeTab,
             .renameTab,
             .nextTab,
             .previousTab,
             .nextTabInProject,
             .previousTabInProject,
             .recentTab,
             .moveTabUp,
             .moveTabDown,
             .separateAllPanes,
             .pinTab,
             .unpinTab: .tabs
        case .splitRight,
             .splitDown,
             .splitAuto,
             .separateCurrentPane,
             .zoomPane,
             .focusLeft,
             .focusRight,
             .focusUp,
             .focusDown,
             .nextPane,
             .previousPane,
             .resizeLeft,
             .resizeRight,
             .resizeUp,
             .resizeDown,
             .movePaneLeft,
             .movePaneRight,
             .movePaneUp,
             .movePaneDown,
             .copySessionID,
             .capturePane,
             .copyMode,
             .readOnlyMode,
             .explainOutput,
             .autofillPassword: .panes
        case .openProject,
             .newRemoteProject,
             .renameProject,
             .unloadProject,
             .removeProject,
             .replaceProjectPathWithCurrentDir,
             .applyLayout,
             .saveLayout,
             .nextProject,
             .previousProject: .projects
        case .toggleSidebar,
             .toggleToolbar,
             .newWindow,
             .newDesktopWidget,
             .closeWindow: .window
        case .settings,
             .reloadGhosttyConfig,
             .openMactermConfig,
             .toggleQuickTerminal,
             .checkForUpdate,
             .capturePaletteScreenshot: .other
        }
    }

    /// The keyboard-binding identity for this command, if any. Commands
    /// without a hotkey are palette-only.
    var hotkeyAction: HotkeyAction? {
        switch self {
        case .newTab: .newTab
        case .closePane: .closePane
        case .closeTab: .closeTab
        case .nextTab: .nextGlobalTab
        case .previousTab: .previousGlobalTab
        case .nextTabInProject: .nextTabInProject
        case .previousTabInProject: .previousTabInProject
        case .recentTab: .recentTab
        case .moveTabUp: .moveTabUp
        case .moveTabDown: .moveTabDown
        case .separateAllPanes: .separateAllPanes
        case .pinTab: .pinTab
        case .unpinTab: .unpinTab
        case .splitRight: .splitRight
        case .splitDown: .splitDown
        case .splitAuto: .splitAuto
        case .separateCurrentPane: .separateCurrentPane
        case .zoomPane: .zoomPane
        case .focusLeft: .focusPaneLeft
        case .focusRight: .focusPaneRight
        case .focusUp: .focusPaneUp
        case .focusDown: .focusPaneDown
        case .nextPane: .nextPane
        case .previousPane: .previousPane
        case .resizeLeft: .resizePaneLeft
        case .resizeRight: .resizePaneRight
        case .resizeUp: .resizePaneUp
        case .resizeDown: .resizePaneDown
        case .movePaneLeft: .movePaneLeft
        case .movePaneRight: .movePaneRight
        case .movePaneUp: .movePaneUp
        case .movePaneDown: .movePaneDown
        case .openProject: .openProject
        case .nextProject: .nextProject
        case .previousProject: .previousProject
        case .toggleSidebar: .toggleSidebar
        case .toggleToolbar: .toggleToolbar
        case .newWindow: .newWindow
        case .closeWindow: .closeWindow
        case .toggleCommandPalette: .toggleCommandPalette
        case .settings: .settings
        case .reloadGhosttyConfig: .reloadGhosttyConfig
        case .openMactermConfig: .openMactermConfig
        case .toggleQuickTerminal: .toggleQuickTerminal
        case .renameTab: .renameTab
        case .renameProject: .renameProject
        case .copySessionID: .copySessionID
        case .capturePane: .capturePane
        case .copyMode: .copyMode
        case .readOnlyMode: .readOnlyMode
        case .explainOutput: .explainOutput
        case .autofillPassword: .autofillPassword
        case .passwordManager: .passwordManager
        case .files: .files
        case .capturePaletteScreenshot: .capturePaletteScreenshot
        case .applyLayout: .applyLayout
        case .saveLayout: .saveLayout
        case .newRemoteProject,
             .newDesktopWidget,
             .unloadProject,
             .removeProject,
             .replaceProjectPathWithCurrentDir,
             .checkForUpdate: nil
        }
    }

    /// The palette screen this command is (`PaletteScope`), if it is one.
    /// Its palette row enters the scope in place; anywhere else — the menu
    /// bar, a keybind — its action opens the palette on it.
    var paletteScope: PaletteScopeID? {
        switch self {
        case .passwordManager: .passwords
        case .files: .files
        default: nil
        }
    }

    /// The raw value is an identifier, never shown: `title` is the label.
    enum Category: String {
        case palettes = "Palettes"
        case tabs = "Tabs"
        case panes = "Panes"
        case projects = "Projects"
        case window = "Window"
        case other = "Other"

        var title: String {
            switch self {
            case .palettes: String(localized: "Palettes", comment: "Command category")
            case .tabs: String(localized: "Tabs", comment: "Command category")
            case .panes: String(localized: "Panes", comment: "Command category")
            case .projects: String(localized: "Projects")
            case .window: String(localized: "Window", comment: "Command category")
            case .other: String(localized: "Other", comment: "Command category")
            }
        }
    }
}

extension HotkeyAction {
    /// Memoized reverse map: `HotkeyAction` → the `AppCommand` that owns it.
    /// Built once instead of an O(n) `allCases` scan per lookup (called per
    /// action per Settings/palette render).
    private static let commandByAction: [HotkeyAction: AppCommand] = Dictionary(
        AppCommand.allCases.compactMap { command in
            command.hotkeyAction.map { ($0, command) }
        },
        uniquingKeysWith: { first, _ in first }
    )

    /// Reverse lookup: the AppCommand that owns this binding. Every
    /// `HotkeyAction` is linked to exactly one `AppCommand`, so a miss is a
    /// construction error (a new action added without its command) — trap in
    /// debug rather than silently mis-titling it as "New Tab".
    var appCommand: AppCommand {
        if let command = Self.commandByAction[self] { return command }
        assertionFailure("HotkeyAction \(rawValue) has no owning AppCommand")
        return .newTab
    }
}
