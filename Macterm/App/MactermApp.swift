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
                .alert(
                    "Close running process?",
                    isPresented: Binding(
                        get: { appState.pendingClosePane != nil },
                        set: { if !$0 { appState.cancelPendingClosePane() } }
                    )
                ) {
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
                    appDelegate.installResponders(appState: appState, projectStore: projectStore)
                }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuItem()
            }
        }

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

    private var windowObserver: Any?
    private var mainAppResponder: MainAppResponder?
    private var hasInstalledResponders = false

    func applicationDidFinishLaunching(_: Notification) {
        // Skip the heavy launch path when the app is hosting unit tests.
        // Without this, libghostty boots, the key router installs, etc. —
        // which times out the xctest runner that just wants to load our
        // module symbols. ProcessInfo.environment is the standard way to
        // detect xctest hosting (Xcode sets this env var).
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        _ = GhosttyApp.shared
        _ = QuickTerminalService.shared
        KeyRouter.shared.install()
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                if self.mainWindow == nil { self.mainWindow = window }
                self.mainAppResponder?.mainWindow = window
            }
        }
    }

    /// Called from MactermApp.onAppear once the state objects exist. Registers
    /// responders in priority order: palette first, quick terminal second,
    /// main app last.
    func installResponders(appState: AppState, projectStore: ProjectStore) {
        guard !hasInstalledResponders else { return }
        hasInstalledResponders = true
        KeyRouter.shared.register(PaletteResponder(appState: appState))
        KeyRouter.shared.register(QuickTerminalResponder())
        let mainResponder = MainAppResponder(appState: appState, projectStore: projectStore)
        mainResponder.mainWindow = mainWindow
        mainAppResponder = mainResponder
        KeyRouter.shared.register(mainResponder)
        // Tab-cycle commit on Ctrl-release.
        KeyRouter.shared.registerFlagsHandler { [weak appState] event in
            guard let appState, appState.isTabCycling else { return }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(.control),
               let projectID = appState.activeProjectID
            {
                appState.commitTabCycle(projectID: projectID)
            }
        }
    }

    func applicationWillTerminate(_: Notification) {
        onTerminate?()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let mainHasRunning =
            appState?.workspaces.values.contains { ws in
                ws.tabs.contains { tab in
                    tab.splitRoot.allPanes().contains { $0.nsView?.needsConfirmQuit() == true }
                }
            } ?? false
        let qtHasRunning = QuickTerminalService.shared.splitState.splitRoot
            .allPanes().contains { $0.nsView?.needsConfirmQuit() == true }
        let hasRunning = mainHasRunning || qtHasRunning
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
}
