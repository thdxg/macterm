import AppIntents

/// The `HotkeyAction`s a shortcut can invoke, as a Shortcuts picker.
///
/// Deriving this from `HotkeyAction.allCases` would be nicer and is not
/// possible: `appintentsmetadataprocessor` reads `caseDisplayRepresentations`
/// out of the *source* at build time and rejects anything but a literal
/// dictionary ("Unexpected value found for 'caseDisplayRepresentations', must
/// be a dictionary"), so both the case list and the labels have to be spelled
/// out. `MactermIntentsTests` pins that the cases cover `HotkeyAction.allCases`
/// exactly and that every label equals its owning `AppCommand.title`, which is
/// what keeps this copy honest — a new keybind fails a test rather than quietly
/// missing from the picker.
///
/// Raw values ARE the persisted `HotkeyAction` ids, so a shortcut written today
/// keeps working across renames of the Swift case; an id retired upstream
/// becomes a shortcut that fails with `.badInput` rather than one that silently
/// invokes something else.
enum MactermKeybind: String, AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Keybind Action")

    case newTab = "new_tab"
    case closePane = "close_pane"
    case closeTab = "close_tab"
    case splitRight = "split_right"
    case splitDown = "split_down"
    case splitAuto = "split_auto"
    case toggleSidebar = "toggle_sidebar"
    case recentTab = "recent_tab"
    case nextProject = "next_project"
    case previousProject = "previous_project"
    case nextGlobalTab = "next_global_tab"
    case previousGlobalTab = "previous_global_tab"
    case nextTabInProject = "next_tab_in_project"
    case previousTabInProject = "previous_tab_in_project"
    case focusPaneLeft = "focus_pane_left"
    case focusPaneDown = "focus_pane_down"
    case focusPaneUp = "focus_pane_up"
    case focusPaneRight = "focus_pane_right"
    case nextPane = "next_pane"
    case previousPane = "previous_pane"
    case resizePaneLeft = "resize_pane_left"
    case resizePaneDown = "resize_pane_down"
    case resizePaneUp = "resize_pane_up"
    case resizePaneRight = "resize_pane_right"
    case newWindow = "new_window"
    case closeWindow = "close_window"
    case openProject = "open_project"
    case zoomPane = "zoom_pane"
    case toggleCommandPalette = "toggle_command_palette"
    case reloadGhosttyConfig = "reload_ghostty_config"
    case toggleQuickTerminal = "toggle_quick_terminal"
    case renameTab = "rename_tab"
    case renameProject = "rename_project"
    case copySessionID = "copy_session_id"
    case applyLayout = "apply_layout"
    case saveLayout = "save_layout"
    case separateAllPanes = "separate_all_panes"
    case separateCurrentPane = "separate_current_pane"
    case pinTab = "pin_tab"
    case unpinTab = "unpin_tab"

    /// The action this case names, nil if it has been retired upstream.
    var hotkeyAction: HotkeyAction? { HotkeyAction(rawValue: rawValue) }

    /// Each label is its owning `AppCommand`'s title verbatim, so the picker
    /// reads exactly like the command palette and the menu bar. A literal by
    /// necessity (see the type comment); the test pins it against the real
    /// titles.
    static let caseDisplayRepresentations: [MactermKeybind: DisplayRepresentation] = [
        .newTab: "New Tab",
        .closePane: "Close Pane",
        .closeTab: "Close Tab",
        .splitRight: "Split Right",
        .splitDown: "Split Down",
        .splitAuto: "Split Automatically",
        .toggleSidebar: "Toggle Sidebar",
        .recentTab: "Recent Tab",
        .nextProject: "Next Project",
        .previousProject: "Previous Project",
        .nextGlobalTab: "Next Tab",
        .previousGlobalTab: "Previous Tab",
        .nextTabInProject: "Next Tab in Project",
        .previousTabInProject: "Previous Tab in Project",
        .focusPaneLeft: "Focus Left",
        .focusPaneDown: "Focus Down",
        .focusPaneUp: "Focus Up",
        .focusPaneRight: "Focus Right",
        .nextPane: "Next Pane",
        .previousPane: "Previous Pane",
        .resizePaneLeft: "Resize Pane Left",
        .resizePaneDown: "Resize Pane Down",
        .resizePaneUp: "Resize Pane Up",
        .resizePaneRight: "Resize Pane Right",
        .newWindow: "New Window",
        .closeWindow: "Close Window",
        .openProject: "Open Project",
        .zoomPane: "Zoom Pane",
        .toggleCommandPalette: "Command Palette",
        .reloadGhosttyConfig: "Reload Ghostty Config",
        .toggleQuickTerminal: "Toggle Quick Terminal",
        .renameTab: "Rename Current Tab",
        .renameProject: "Rename Current Project",
        .copySessionID: "Copy Session ID",
        .applyLayout: "Apply Layout",
        .saveLayout: "Save Layout",
        .separateAllPanes: "Separate All Panes",
        .separateCurrentPane: "Separate Current Pane",
        .pinTab: "Pin Tab",
        .unpinTab: "Unpin Tab",
    ]
}

/// Invoke one of the app's own keybind actions — the fourth renderer of
/// `AppCommand`, after the palette, the menus and the Dock.
///
/// Nothing here decides what an action does: it resolves the `AppCommand` that
/// owns the binding and runs the same closure every other surface runs, through
/// the same "arrived from outside the app" preparation the Dock menu uses. The
/// return value says whether the action applied — an action that doesn't (New
/// Tab with no project) is a `false`, not an error, so a shortcut can branch on
/// it instead of failing.
struct InvokeMactermKeybindIntent: AppIntent {
    static let title: LocalizedStringResource = "Invoke Keybind"
    static let description = IntentDescription("Run one of the app's keybind actions.")

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = [.background, .foreground]
    #endif

    @Parameter(title: "Action")
    var keybind: MactermKeybind

    static var parameterSummary: some ParameterSummary {
        Summary("Invoke \(\.$keybind)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let ctx = try await MactermIntentHost.shared.authorizedContext()
        guard let action = keybind.hotkeyAction else {
            throw MactermIntentError.badInput("\"\(keybind.rawValue)\" is no longer an action in \(appDisplayName).")
        }
        guard let delegate = ctx.appState.appDelegate else {
            throw MactermIntentError.appUnavailable
        }
        return .result(value: delegate.performExternalCommand(action.appCommand, source: "intent"))
    }
}

/// Show or hide the quick terminal.
///
/// The one command with nothing to prepare: the panel is a non-activating
/// `NSPanel` that manages its own focus, so fronting a window or activating the
/// app here would steal focus from whatever the user is in — exactly what its
/// `show()` goes out of its way not to do. `DockMenu.preparation` already says
/// so; this runs through it rather than restating the rule.
struct ToggleMactermQuickTerminalIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Quick Terminal"
    static let description = IntentDescription("Show or hide the quick terminal overlay.")

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = [.background, .foreground]
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        let ctx = try await MactermIntentHost.shared.authorizedContext()
        guard let delegate = ctx.appState.appDelegate else {
            throw MactermIntentError.appUnavailable
        }
        delegate.performExternalCommand(.toggleQuickTerminal, source: "intent")
        return .result()
    }
}

/// Open the command palette in the window the user is in.
struct OpenMactermCommandPaletteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Command Palette"
    static let description = IntentDescription("Open the command palette in the frontmost window.")

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .foreground
    #endif

    @MainActor
    func perform() async throws -> some IntentResult {
        let ctx = try await MactermIntentHost.shared.authorizedContext()
        guard let delegate = ctx.appState.appDelegate else {
            throw MactermIntentError.appUnavailable
        }
        // The palette is for a person to type into, so unlike every other
        // intent this one is only useful with the app in front — the
        // `frontTerminalWindow` preparation fronts the window, and the
        // foreground mode gets the app itself activated.
        delegate.performExternalCommand(.toggleCommandPalette, source: "intent")
        return .result()
    }
}
