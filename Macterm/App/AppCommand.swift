import Foundation

/// Single source of truth for every user-invokable action — both palette
/// commands and keyboard-bindable ones. Exposes a sentence-cased `title` and
/// a `category` so the palette and Settings can render the same list without
/// duplicated strings. The optional `hotkeyAction` link says whether a
/// command is rebindable; palette-only commands (like renaming the current
/// project) return nil.
enum AppCommand: String, CaseIterable, Identifiable {
    // Tabs
    case newTab
    case closePane
    case nextTab
    case previousTab
    case recentTab
    // Panes
    case splitRight
    case splitDown
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
    case removeProject
    case nextProject
    case previousProject
    // Window
    case toggleSidebar
    case closeWindow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newTab: "New tab"
        case .closePane: "Close pane"
        case .nextTab: "Next tab"
        case .previousTab: "Previous tab"
        case .recentTab: "Recent tab"
        case .splitRight: "Split right"
        case .splitDown: "Split down"
        case .focusLeft: "Focus left"
        case .focusRight: "Focus right"
        case .focusUp: "Focus up"
        case .focusDown: "Focus down"
        case .resizeLeft: "Resize pane left"
        case .resizeRight: "Resize pane right"
        case .resizeUp: "Resize pane up"
        case .resizeDown: "Resize pane down"
        case .openProject: "Open project"
        case .renameProject: "Rename current project"
        case .removeProject: "Remove current project"
        case .nextProject: "Next project"
        case .previousProject: "Previous project"
        case .toggleSidebar: "Toggle sidebar"
        case .closeWindow: "Close window"
        }
    }

    var category: Category {
        switch self {
        case .newTab,
             .closePane,
             .nextTab,
             .previousTab,
             .recentTab: .tabs
        case .splitRight,
             .splitDown,
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
             .removeProject,
             .nextProject,
             .previousProject: .projects
        case .toggleSidebar,
             .closeWindow: .window
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
        case .renameProject,
             .removeProject: nil
        }
    }

    enum Category: String {
        case tabs = "Tabs"
        case panes = "Panes"
        case projects = "Projects"
        case window = "Window"
    }
}

extension HotkeyAction {
    /// Reverse lookup: the AppCommand that owns this binding.
    var appCommand: AppCommand {
        AppCommand.allCases.first(where: { $0.hotkeyAction == self }) ?? .newTab
    }
}
