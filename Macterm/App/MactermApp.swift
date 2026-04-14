import AppKit
import SwiftUI

@main
struct MactermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate
    @State
    private var appState = AppState()
    @State
    private var projectStore = ProjectStore()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(appState)
                .environment(projectStore)
                .preferredColorScheme(MactermTheme.colorScheme)
                .alert("Close running process?", isPresented: Binding(
                    get: { appState.pendingClosePane != nil },
                    set: { if !$0 { appState.cancelPendingClosePane() } }
                )) {
                    Button("Cancel", role: .cancel) {
                        appState.cancelPendingClosePane()
                    }
                    Button("Close", role: .destructive) {
                        appState.confirmPendingClosePane()
                    }
                } message: {
                    Text("A process is still running in this pane. Close it anyway?")
                }
                .onAppear {
                    appDelegate.appState = appState
                    appDelegate.projectStore = projectStore
                    appDelegate.onTerminate = { [appState] in appState.saveWorkspaces() }
                }
        }
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    var appState: AppState?
    var projectStore: ProjectStore?
    var mainWindow: NSWindow?
    private var keyMonitor: Any?

    private var windowObserver: Any?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        setAppIcon()
        _ = GhosttyApp.shared
        _ = QuickTerminalService.shared
        installKeyMonitor()
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard self?.mainWindow == nil, let window else { return }
                self?.mainWindow = window
            }
        }
    }

    func applicationWillTerminate(_: Notification) {
        onTerminate?()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasRunning = TerminalViewCache.shared.anyNeedsConfirmQuit()
            || QuickTerminalService.shared.viewCache.anyNeedsConfirmQuit()
        guard hasRunning else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Quit Macterm?"
        alert.informativeText = "There are still processes running. Quit anyway?"
        alert.alertStyle = .warning
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        return false
    }

    private var flagsMonitor: Any?

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event) == true ? nil : event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard let appState, appState.isTabCycling else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !flags.contains(.control) {
            guard let projectID = appState.activeProjectID else { return }
            appState.commitTabCycle(projectID: projectID)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let appState else { return false }

        if HotkeyCaptureState.shared.isCapturing {
            return false
        }

        // Handle quick terminal keybinds when it's visible
        if QuickTerminalService.shared.isVisible {
            return handleQuickTerminalKeyEvent(event)
        }

        if HotkeyRegistry.matches(event, action: .recentTab) {
            guard let projectID = appState.activeProjectID else { return false }
            appState.cycleRecentTab(projectID: projectID)
            return true
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 50, flags.contains(.control) {
            NotificationCenter.default.post(name: .toggleQuickTerminal, object: nil)
            return true
        }

        if HotkeyRegistry.matches(event, action: .newTab) {
            guard let projectID = appState.activeProjectID else { return false }
            appState.createTab(projectID: projectID)
            return true
        }

        if HotkeyRegistry.matches(event, action: .closePane) {
            guard let projectID = appState.activeProjectID,
                  let pane = appState.focusedPane(for: projectID)
            else { return false }
            appState.requestClosePane(pane.id, projectID: projectID)
            return true
        }

        if HotkeyRegistry.matches(event, action: .splitRight) {
            guard let projectID = appState.activeProjectID else { return false }
            appState.splitPane(direction: .horizontal, projectID: projectID)
            return true
        }

        if HotkeyRegistry.matches(event, action: .splitDown) {
            guard let projectID = appState.activeProjectID else { return false }
            appState.splitPane(direction: .vertical, projectID: projectID)
            return true
        }

        if HotkeyRegistry.matches(event, action: .toggleSidebar) {
            appState.sidebarVisible.toggle()
            return true
        }

        if HotkeyRegistry.matches(event, action: .nextProject) {
            guard let projectStore else { return false }
            appState.selectNextProject(projects: projectStore.projects)
            return true
        }

        if HotkeyRegistry.matches(event, action: .previousProject) {
            guard let projectStore else { return false }
            appState.selectPreviousProject(projects: projectStore.projects)
            return true
        }

        if HotkeyRegistry.matches(event, action: .nextGlobalTab) {
            guard let projectStore else { return false }
            appState.selectGlobalTab(.next, projects: projectStore.projects)
            return true
        }

        if HotkeyRegistry.matches(event, action: .previousGlobalTab) {
            guard let projectStore else { return false }
            appState.selectGlobalTab(.previous, projects: projectStore.projects)
            return true
        }

        if let (_, dir) = Self.paneActions.first(where: { HotkeyRegistry.matches(event, action: $0.0) }) {
            guard let projectID = appState.activeProjectID else { return false }
            appState.focusPaneInDirection(dir, projectID: projectID)
            return true
        }

        if HotkeyRegistry.matches(event, action: .closeWindow) {
            mainWindow?.orderOut(nil)
            return true
        }

        if HotkeyRegistry.matches(event, action: .openProject) {
            guard let projectStore else { return false }
            _ = appState.openProject(store: projectStore)
            return true
        }

        guard flags.contains(.command) else { return false }

        let hasOption = flags.contains(.option)
        if !hasOption {
            let key = (event.charactersIgnoringModifiers ?? "").lowercased()
            if let idx = Int(key), idx >= 1, idx <= 9,
               let projectID = appState.activeProjectID
            {
                appState.selectTabByIndex(idx - 1, projectID: projectID)
                return true
            }
        }

        return false
    }

    private static let paneActions: [(HotkeyAction, PaneFocusDirection)] = [
        (.focusPaneLeft, .left),
        (.focusPaneDown, .down),
        (.focusPaneUp, .up),
        (.focusPaneRight, .right),
    ]

    private func handleQuickTerminalKeyEvent(_ event: NSEvent) -> Bool {
        let qt = QuickTerminalService.shared
        let state = qt.splitState

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 50, flags.contains(.control) {
            NotificationCenter.default.post(name: .toggleQuickTerminal, object: nil)
            return true
        }

        if HotkeyRegistry.matches(event, action: .splitRight) {
            guard let paneID = state.focusedPaneID else { return false }
            state.split(paneID: paneID, direction: .horizontal)
            return true
        }

        if HotkeyRegistry.matches(event, action: .splitDown) {
            guard let paneID = state.focusedPaneID else { return false }
            state.split(paneID: paneID, direction: .vertical)
            return true
        }

        if HotkeyRegistry.matches(event, action: .closePane) {
            guard let paneID = state.focusedPaneID else { return false }
            state.closePane(paneID, viewCache: qt.viewCache)
            return true
        }

        if let (_, dir) = Self.paneActions.first(where: { HotkeyRegistry.matches(event, action: $0.0) }) {
            guard let focusedID = state.focusedPaneID else { return false }
            if let bestID = state.splitRoot.nearestPane(from: focusedID, direction: dir) {
                state.focusedPaneID = bestID
            }
            return true
        }

        return false
    }

    @MainActor
    private func setAppIcon() {
        guard let url = Bundle.appResources.url(forResource: "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return }
        NSApp.applicationIconImage = image
    }
}
