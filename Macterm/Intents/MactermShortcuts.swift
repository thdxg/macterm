import AppIntents

/// The shortcuts the app offers up front — what Spotlight and the Shortcuts
/// gallery show without the user assembling anything.
///
/// Deliberately short. Ghostty ships no provider at all (its intents are
/// discovered from the metadata alone), and every phrase here is a name the
/// user could say out loud by accident, so this covers only the actions that
/// take no parameters or one obvious one. Everything else is still available in
/// the Shortcuts editor — a provider is a shortlist, not the surface.
///
/// `\(.applicationName)` is required in every phrase: App Intents rejects a
/// phrase that doesn't name the app.
struct MactermShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleMactermQuickTerminalIntent(),
            phrases: [
                "Toggle the \(.applicationName) quick terminal",
                "Open the \(.applicationName) quick terminal",
            ],
            shortTitle: "Toggle Quick Terminal",
            systemImageName: "macwindow.on.rectangle"
        )
        AppShortcut(
            intent: OpenMactermCommandPaletteIntent(),
            phrases: [
                "Open the \(.applicationName) command palette",
            ],
            shortTitle: "Open Command Palette",
            systemImageName: "command"
        )
        AppShortcut(
            intent: NewMactermTabIntent(),
            phrases: [
                "New \(.applicationName) tab",
                "Open a new tab in \(.applicationName)",
            ],
            shortTitle: "New Tab",
            systemImageName: "plus.rectangle.on.rectangle"
        )
    }
}
