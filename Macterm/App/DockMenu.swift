import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "DockMenu")

/// The Dock icon's context menu (`applicationDockMenu`): which commands it
/// offers, in order, and what a pick needs before its command can run.
///
/// Every item is an `AppCommand`, run through `AppCommand.action(in:)` — the
/// same closure the menu bar and the palette run — so the Dock menu can never
/// drift from them. This enum is the pure half; `DockMenuTests` asserts the
/// delegate's built menu against it.
enum DockMenu {
    /// The menu, top to bottom. Mirrors Ghostty's Dock menu.
    static let commands: [AppCommand] = [.newWindow, .newTab, .openProject, .toggleQuickTerminal]

    /// The item's title. `AppCommand.title` is the palette's wording; the one
    /// override matches the menu bar's Project menu, which also calls the
    /// folder picker "New Project…" (the File menu's "Open Project…" is the
    /// same command — from the Dock the user is making something, not
    /// reopening it).
    static func title(for command: AppCommand) -> String {
        switch command {
        case .openProject: "New Project…"
        default: command.title
        }
    }

    /// What a pick does before the command runs.
    ///
    /// The Dock menu is reached from outside the app: unlike a menu-bar pick,
    /// nothing has activated Macterm or fronted a window by the time the item
    /// fires, and choosing a Dock menu item does not activate the app on its
    /// own.
    enum Preparation: Equatable {
        /// Run the command as-is. The quick terminal is a non-activating
        /// panel that manages focus itself — activating the app here would
        /// steal focus from whatever the user was in, which is exactly what
        /// its `show()` goes out of its way not to do.
        case none
        /// Bring Macterm forward; the command makes its own window.
        case activate
        /// Front a terminal window first, opening one if the launch never
        /// produced any (`AppDelegate.showWindow`), because the command acts
        /// inside the window the user is in — and from the Dock that window
        /// may be hidden behind the last close, or not exist at all (#241).
        case frontTerminalWindow
    }

    static func preparation(for command: AppCommand) -> Preparation {
        switch command {
        case .newTab,
             .openProject: .frontTerminalWindow
        case .toggleQuickTerminal: .none
        default: .activate
        }
    }
}

extension AppDelegate {
    /// Built fresh on every right-click, so an item is enabled exactly when
    /// its command applies right now (New Tab with no project is greyed, as
    /// in the menu bar). Nil — AppKit's stock menu — until `MainWindow` has
    /// handed over the state objects, since nothing could run before then.
    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        guard let appState, let projectStore else { return nil }
        let ctx = AppCommandContext(appState: appState, projectStore: projectStore)
        let menu = NSMenu()
        menu.autoenablesItems = false
        for command in DockMenu.commands {
            let item = NSMenuItem(
                title: DockMenu.title(for: command),
                action: #selector(dockMenuItemPicked(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = command
            item.isEnabled = command.action(in: ctx) != nil
            menu.addItem(item)
        }
        return menu
    }

    @objc
    func dockMenuItemPicked(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? AppCommand else { return }
        performDockMenuCommand(command)
    }

    /// Run a Dock menu pick: prepare (see `DockMenu.Preparation`), then run
    /// the command's own action. The action is resolved AFTER preparing —
    /// fronting a window makes it key, which is what `activeProjectID`
    /// mirrors — and a command that stopped applying between the right-click
    /// and the pick is a no-op rather than a crash.
    func performDockMenuCommand(_ command: AppCommand) {
        guard let appState, let projectStore else { return }
        switch DockMenu.preparation(for: command) {
        case .none:
            break
        case .activate:
            NSApp.activate()
        case .frontTerminalWindow:
            showWindow()
        }
        let ctx = AppCommandContext(appState: appState, projectStore: projectStore)
        guard let action = command.action(in: ctx) else {
            logger.info("dock menu: \(command.rawValue, privacy: .public) does not apply right now")
            return
        }
        logger.info("dock menu: \(command.rawValue, privacy: .public)")
        action()
    }
}
