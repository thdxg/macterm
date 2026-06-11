import Foundation

/// Single source of truth for every user-invokable action — both palette
/// commands and keyboard-bindable ones. Exposes a title-cased `title` (macOS
/// menu convention) and a `category` so the palette and Settings can render the same list without
/// duplicated strings. The optional `hotkeyAction` link says whether a
/// command is rebindable; palette-only commands (like renaming the current
/// project) return nil.
enum AppCommand: String, CaseIterable, Identifiable {
    // Tabs
    case newTab
    case closePane
    case renameTab
    case nextTab
    case previousTab
    case recentTab
    // Panes
    case splitRight
    case splitDown
    case splitAuto
    case zoomPane
    case focusLeft
    case focusRight
    case focusUp
    case focusDown
    case resizeLeft
    case resizeRight
    case resizeUp
    case resizeDown
    // Projects
    case openProject
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
    case closeWindow
    case toggleCommandPalette
    case reloadGhosttyConfig
    case toggleQuickTerminal
    case checkForUpdate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTab: "New Tab"
        case .closePane: "Close Pane"
        case .renameTab: "Rename Current Tab"
        case .nextTab: "Next Tab"
        case .previousTab: "Previous Tab"
        case .recentTab: "Recent Tab"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .splitAuto: "Split Automatically"
        case .zoomPane: "Zoom Pane"
        case .focusLeft: "Focus Left"
        case .focusRight: "Focus Right"
        case .focusUp: "Focus Up"
        case .focusDown: "Focus Down"
        case .resizeLeft: "Resize Pane Left"
        case .resizeRight: "Resize Pane Right"
        case .resizeUp: "Resize Pane Up"
        case .resizeDown: "Resize Pane Down"
        case .openProject: "Open Project"
        case .renameProject: "Rename Current Project"
        case .unloadProject: "Unload Current Project"
        case .removeProject: "Remove Current Project"
        case .replaceProjectPathWithCurrentDir: "Replace Project Path with Current Directory"
        case .applyLayout: "Apply Layout"
        case .saveLayout: "Save Layout"
        case .nextProject: "Next Project"
        case .previousProject: "Previous Project"
        case .toggleSidebar: "Toggle Sidebar"
        case .closeWindow: "Close Window"
        case .toggleCommandPalette: "Command Palette"
        case .reloadGhosttyConfig: "Reload Ghostty Config"
        case .toggleQuickTerminal: "Toggle Quick Terminal"
        case .checkForUpdate: "Check for Update"
        }
    }

    var category: Category {
        switch self {
        case .newTab,
             .closePane,
             .renameTab,
             .nextTab,
             .previousTab,
             .recentTab: .tabs
        case .splitRight,
             .splitDown,
             .splitAuto,
             .zoomPane,
             .focusLeft,
             .focusRight,
             .focusUp,
             .focusDown,
             .resizeLeft,
             .resizeRight,
             .resizeUp,
             .resizeDown: .panes
        case .openProject,
             .renameProject,
             .unloadProject,
             .removeProject,
             .replaceProjectPathWithCurrentDir,
             .applyLayout,
             .saveLayout,
             .nextProject,
             .previousProject: .projects
        case .toggleSidebar,
             .closeWindow,
             .toggleCommandPalette: .window
        case .reloadGhosttyConfig,
             .toggleQuickTerminal,
             .checkForUpdate: .other
        }
    }

    /// The keyboard-binding identity for this command, if any. Commands
    /// without a hotkey are palette-only.
    var hotkeyAction: HotkeyAction? {
        switch self {
        case .newTab: .newTab
        case .closePane: .closePane
        case .nextTab: .nextGlobalTab
        case .previousTab: .previousGlobalTab
        case .recentTab: .recentTab
        case .splitRight: .splitRight
        case .splitDown: .splitDown
        case .splitAuto: .splitAuto
        case .zoomPane: .zoomPane
        case .focusLeft: .focusPaneLeft
        case .focusRight: .focusPaneRight
        case .focusUp: .focusPaneUp
        case .focusDown: .focusPaneDown
        case .resizeLeft: .resizePaneLeft
        case .resizeRight: .resizePaneRight
        case .resizeUp: .resizePaneUp
        case .resizeDown: .resizePaneDown
        case .openProject: .openProject
        case .nextProject: .nextProject
        case .previousProject: .previousProject
        case .toggleSidebar: .toggleSidebar
        case .closeWindow: .closeWindow
        case .toggleCommandPalette: .toggleCommandPalette
        case .reloadGhosttyConfig: .reloadGhosttyConfig
        case .toggleQuickTerminal: .toggleQuickTerminal
        case .renameTab: .renameTab
        case .renameProject: .renameProject
        case .unloadProject,
             .removeProject,
             .replaceProjectPathWithCurrentDir,
             .applyLayout,
             .saveLayout,
             .checkForUpdate: nil
        }
    }

    enum Category: String {
        case tabs = "Tabs"
        case panes = "Panes"
        case projects = "Projects"
        case window = "Window"
        case other = "Other"
    }
}

extension HotkeyAction {
    /// Reverse lookup: the AppCommand that owns this binding.
    var appCommand: AppCommand {
        AppCommand.allCases.first(where: { $0.hotkeyAction == self }) ?? .newTab
    }
}
