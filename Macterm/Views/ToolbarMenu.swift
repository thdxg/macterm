import AppKit
import SwiftUI

/// The terminal window toolbar's right-click menu: Hide Toolbar, plus the tab
/// switcher's two settings, so the bar can be arranged from the bar itself
/// rather than only from Settings → Appearance → Toolbar.
///
/// AppKit offers no hook for it. The bar is SwiftUI's `NSToolbar`, whose own
/// context menu is empty once display-mode customization is locked
/// (`WindowAppearance.syncToolbar`), and a right-click there is consumed
/// without reaching `NSView.menu` on the titlebar views (measured: a menu
/// set on `NSTitlebarContainerView` never opened). So a local monitor takes
/// a secondary click whose hit view sits in a terminal window's titlebar
/// container — the toolbar items, the title and the empty bar alike — and
/// opens the menu there; every other click passes through untouched.
///
/// One menu serves every window. It is rebuilt each time it opens
/// (`menuNeedsUpdate`), so its checkmarks follow `Preferences` however they
/// last changed (Settings or another window's menu). Hide Toolbar flips the
/// same preference as Settings' Show toolbar toggle; the way back is that
/// toggle or View → Show Toolbar (`ToolbarVisibilityMenuItem`), since a
/// hidden toolbar takes this menu with it.
@MainActor
final class ToolbarMenu: NSObject, NSMenuDelegate {
    static let shared = ToolbarMenu()

    let menu = NSMenu(title: "Toolbar")
    private weak var appState: AppState?
    private var monitor: Any?

    override private init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
    }

    /// Installed by `AppDelegate.installResponders`: telling a terminal
    /// window from Settings or a panel needs the delegate's window registry.
    func attach(appState: AppState) {
        self.appState = appState
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self, opensMenu(for: event), let view = event.window?.contentView else { return event }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return nil
        }
    }

    /// A secondary click (right button, or control-click) on the titlebar of
    /// a terminal window — including the separate overlay window AppKit hosts
    /// the toolbar in during native full screen.
    private func opensMenu(for event: NSEvent) -> Bool {
        let secondary = event.type == .rightMouseDown
            || event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control)
        guard secondary, !Preferences.shared.hideTitleBar,
              let window = event.window,
              let delegate = appState?.appDelegate
        else { return false }
        let terminalWindow = window.className == "NSToolbarFullScreenWindow" ? window.parent : window
        guard let terminalWindow, delegate.isTerminalWindow(terminalWindow),
              let root = window.contentView?.superview,
              var view = root.hitTest(event.locationInWindow)
        else { return false }
        while true {
            if view.className == "NSTitlebarContainerView" { return true }
            guard let parent = view.superview else { return false }
            view = parent
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let prefs = Preferences.shared

        let hide = NSMenuItem(title: "Hide Toolbar", action: #selector(hideToolbar(_:)), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.addItem(.separator())

        // One submenu, two sections — the same two settings as Settings →
        // Appearance → Toolbar, headed the way the Settings pickers label them.
        let switcher = NSMenu(title: "Tab Switcher")
        switcher.autoenablesItems = false
        switcher.addItem(.sectionHeader(title: "Show"))
        addOptions(
            TabSwitcherVisibility.allCases,
            selected: prefs.tabSwitcherVisibility,
            label: \.displayName,
            action: #selector(setTabSwitcherVisibility(_:)),
            to: switcher
        )
        switcher.addItem(.separator())
        switcher.addItem(.sectionHeader(title: "Position"))
        addOptions(
            TabSwitcherPosition.allCases,
            selected: prefs.tabSwitcherPosition,
            label: \.displayName,
            action: #selector(setTabSwitcherPosition(_:)),
            to: switcher
        )
        let parent = NSMenuItem(title: "Tab Switcher", action: nil, keyEquivalent: "")
        parent.submenu = switcher
        menu.addItem(parent)
    }

    /// A preference's choices with the current one checked; each item carries
    /// its choice's raw value for `action` to read back.
    private func addOptions<Option: RawRepresentable & Equatable>(
        _ options: [Option],
        selected: Option,
        label: KeyPath<Option, String>,
        action: Selector,
        to menu: NSMenu
    ) where Option.RawValue == String {
        for option in options {
            let item = NSMenuItem(title: option[keyPath: label], action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == selected ? .on : .off
            menu.addItem(item)
        }
    }

    @objc
    private func hideToolbar(_: NSMenuItem) {
        Preferences.shared.hideTitleBar = true
    }

    @objc
    private func setTabSwitcherVisibility(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let value = TabSwitcherVisibility(rawValue: raw)
        else { return }
        Preferences.shared.tabSwitcherVisibility = value
    }

    @objc
    private func setTabSwitcherPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let value = TabSwitcherPosition(rawValue: raw)
        else { return }
        Preferences.shared.tabSwitcherPosition = value
    }
}

/// View → Hide Toolbar / Show Toolbar: the Settings toggle
/// (`Preferences.hideTitleBar`) in the slot macOS gives it, titled for what a
/// click does. Not an `AppCommand` — it has no keybind or palette row.
/// Observation tracks the `hideTitleBar` read in `body`, so the title follows
/// the setting however it changes.
struct ToolbarVisibilityMenuItem: View {
    private var preferences: Preferences { .shared }

    var body: some View {
        Button(preferences.hideTitleBar ? "Show Toolbar" : "Hide Toolbar") {
            preferences.hideTitleBar.toggle()
        }
    }
}
