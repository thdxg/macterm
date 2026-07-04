import AppKit
import SwiftUI
import UserNotifications

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
                .modifier(AppColorScheme())
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
                .alert(
                    "Apply layout?",
                    isPresented: Binding(
                        get: { appState.pendingLayoutApply != nil },
                        set: { if !$0 { appState.cancelPendingLayoutApply() } }
                    )
                ) {
                    Button("Cancel", role: .cancel) {
                        appState.cancelPendingLayoutApply()
                    }
                    Button("Apply", role: .destructive) {
                        appState.confirmPendingLayoutApply()
                    }
                } message: {
                    if let pending = appState.pendingLayoutApply {
                        Text(pending.confirmationMessage)
                    }
                }
                .onAppear {
                    appDelegate.appState = appState
                    appDelegate.projectStore = projectStore
                    NotificationHandler.shared.appState = appState
                    appDelegate.onTerminate = { [appState] in appState.saveWorkspaces() }
                    appDelegate.installResponders(appState: appState, projectStore: projectStore)
                }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                // Replace SwiftUI's "New Window" with "Show Window", which
                // unhides the single Macterm window after the user clicked
                // the red close button. Without this, hiding the window
                // leaves no menu/keyboard way to bring it back — only the
                // dock icon — and even that depends on AppKit reopen
                // delegation routing back through SwiftUI's WindowGroup.
                Button("Show Window") {
                    if let window = appDelegate.mainWindow {
                        window.makeKeyAndOrderFront(nil)
                        NSApp.activate()
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
                Divider()
                AppCommandMenuItem(command: .newTab, appState: appState, projectStore: projectStore, titleOverride: "New Tab")
                AppCommandMenuItem(command: .openProject, appState: appState, projectStore: projectStore, titleOverride: "Open Project…")
            }
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(after: .appInfo) {
                CheckForUpdatesMenuItem()
            }
            CommandGroup(replacing: .saveItem) {
                AppCommandMenuItem(command: .closePane, appState: appState, projectStore: projectStore, titleOverride: "Close Pane")
                AppCommandMenuItem(command: .closeWindow, appState: appState, projectStore: projectStore, titleOverride: "Close Window")
            }
            CommandGroup(replacing: .sidebar) {
                AppCommandMenuItem(command: .toggleSidebar, appState: appState, projectStore: projectStore, titleOverride: "Toggle Sidebar")
                AppCommandMenuItem(
                    command: .toggleCommandPalette,
                    appState: appState,
                    projectStore: projectStore,
                    titleOverride: "Command Palette"
                )
                AppCommandMenuItem(
                    command: .toggleQuickTerminal,
                    appState: appState,
                    projectStore: projectStore,
                    titleOverride: "Quick Terminal"
                )
                Divider()
                AppCommandMenuItem(
                    command: .reloadGhosttyConfig,
                    appState: appState,
                    projectStore: projectStore,
                    titleOverride: "Reload Ghostty Config"
                )
            }
            CommandGroup(after: .windowList) {
                Divider()
                AppCommandMenuItem(command: .nextTab, appState: appState, projectStore: projectStore, titleOverride: "Next Tab")
                AppCommandMenuItem(command: .previousTab, appState: appState, projectStore: projectStore, titleOverride: "Previous Tab")
                AppCommandMenuItem(command: .recentTab, appState: appState, projectStore: projectStore, titleOverride: "Recent Tab")
            }
            CommandMenu("Project") {
                AppCommandMenuItem(command: .openProject, appState: appState, projectStore: projectStore, titleOverride: "New Project…")
                AppCommandMenuItem(
                    command: .renameProject,
                    appState: appState,
                    projectStore: projectStore,
                    titleOverride: "Rename Project…"
                )
                AppCommandMenuItem(command: .unloadProject, appState: appState, projectStore: projectStore, titleOverride: "Unload Project")
                AppCommandMenuItem(command: .removeProject, appState: appState, projectStore: projectStore, titleOverride: "Remove Project")
                AppCommandMenuItem(
                    command: .replaceProjectPathWithCurrentDir,
                    appState: appState,
                    projectStore: projectStore,
                    titleOverride: "Set Project Path to Current Directory"
                )
                Divider()
                AppCommandMenuItem(command: .nextProject, appState: appState, projectStore: projectStore, titleOverride: "Next Project")
                AppCommandMenuItem(
                    command: .previousProject,
                    appState: appState,
                    projectStore: projectStore,
                    titleOverride: "Previous Project"
                )
            }
        }

        Settings {
            SettingsView()
        }
    }
}

/// Applies the app-wide light/dark scheme derived from the ghostty theme.
///
/// Reading `GhosttyApp.shared.configVersion` (an `@Observable` property bumped
/// on config reload and on system appearance changes) registers a SwiftUI
/// dependency, so `.preferredColorScheme` — and every `MactermTheme` color read
/// downstream — re-evaluates when the resolved theme changes. Without this the
/// chrome would freeze at its launch appearance, since `MactermTheme.colorScheme`
/// reads `NSApp`/theme files rather than observable state (issue #38).
private struct AppColorScheme: ViewModifier {
    @State private var ghostty = GhosttyApp.shared

    func body(content: Content) -> some View {
        // Touch configVersion so SwiftUI tracks it as a dependency and
        // re-evaluates the color scheme when the resolved theme changes.
        _ = ghostty.configVersion
        return content.preferredColorScheme(MactermTheme.colorScheme)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    var appState: AppState?
    var projectStore: ProjectStore?
    var mainWindow: NSWindow?

    private var windowObserver: Any?
    private var activateObserver: Any?
    private var appFocusObservers: [Any] = []
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
        UNUserNotificationCenter.current().delegate = NotificationHandler.shared
        NotificationHandler.shared.requestAuthorization()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        _ = GhosttyApp.shared
        _ = QuickTerminalService.shared
        KeyRouter.shared.install()
        // Dock-icon click on a hidden window: SwiftUI's
        // @NSApplicationDelegateAdaptor swallows applicationShouldHandleReopen,
        // and `didBecomeActiveNotification` doesn't always fire (e.g. when
        // the user clicks the dock icon while the app is already considered
        // active by AppKit). The NSWorkspace activation notification fires
        // reliably on every dock-click, filtered to our own bundle ID so
        // we don't react to other apps.
        activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, bundleID == Bundle.main.bundleIdentifier else { return }
                self.reopenIfNeeded()
            }
        }

        // Tell libghostty when we stop/start being the active app so idle
        // surfaces stop blinking the cursor and animating while backgrounded.
        // Visible terminals keep rendering real output (that's gated by
        // per-surface occlusion, not app focus), so watching a running command
        // from another app still updates.
        let focusCenter = NotificationCenter.default
        appFocusObservers = [
            focusCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { _ in MainActor.assumeIsolated { GhosttyApp.shared.setAppFocus(true) } },
            focusCenter.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { _ in MainActor.assumeIsolated { GhosttyApp.shared.setAppFocus(false) } },
        ]

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

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        let rows = collectRunningProcessRows()
        if rows.isEmpty {
            AppTerminationState.isTerminating = true
            return .terminateNow
        }

        if QuitConfirmation.runModal(rows: rows) {
            AppTerminationState.isTerminating = true
            return .terminateNow
        }
        return .terminateCancel
    }

    /// Walk every workspace + the quick terminal and emit one row per pane
    /// whose ghostty surface still has a foreground process running.
    private func collectRunningProcessRows() -> [RunningProcessRow] {
        var rows: [RunningProcessRow] = []
        let projectsByID = Dictionary(
            uniqueKeysWithValues: (projectStore?.projects ?? []).map { ($0.id, $0) }
        )

        for ws in appState?.workspaces.values ?? [:].values {
            let project = projectsByID[ws.projectID]
            let projectName = project?.name ?? "Project"
            for tab in ws.tabs {
                for pane in tab.splitRoot.allPanes() where pane.nsView?.needsConfirmQuit() == true {
                    // The adaptive poll may be slow or fully paused here (e.g.
                    // quitting a minimized app), so the cached name can be
                    // stale — re-read before showing it in the dialog.
                    pane.refreshForegroundProcess(trackExecution: false)
                    rows.append(RunningProcessRow(
                        projectName: projectName,
                        processName: pane.processTitle
                    ))
                }
            }
        }

        let qtTab = QuickTerminalService.shared.splitState.tab
        for pane in qtTab.splitRoot.allPanes() where pane.nsView?.needsConfirmQuit() == true {
            pane.refreshForegroundProcess(trackExecution: false)
            rows.append(RunningProcessRow(
                projectName: "Quick Terminal",
                processName: pane.processTitle
            ))
        }

        return rows
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    /// Bring our (possibly ordered-out) main window back. Robust to cases
    /// where `self.mainWindow` got stale: walks NSApp.windows for the first
    /// terminal-bearing window, falling back to the cached pointer.
    /// Bring our (possibly ordered-out) main window back. Robust to cases
    /// where `self.mainWindow` got stale: walks NSApp.windows for the first
    /// terminal-bearing window, falling back to the cached pointer.
    func reopenIfNeeded() {
        // If a non-panel window is already visible, nothing to do.
        if NSApp.windows.contains(where: { $0.isVisible && !($0 is NSPanel) }) {
            return
        }

        // Find the hidden main window. Don't filter on `canBecomeMain` — AppKit
        // reports that as false for ordered-out SwiftUI windows (which is
        // exactly the case we're handling). Filter on class instead: skip
        // panels (quick terminal, settings).
        let target = NSApp.windows.first { window in
            !window.isVisible && !(window is NSPanel)
        } ?? mainWindow

        guard let target else { return }
        target.makeKeyAndOrderFront(nil)
        NSApp.activate()
        if mainWindow !== target {
            mainWindow = target
            mainAppResponder?.mainWindow = target
        }
    }

    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        return false
    }
}
