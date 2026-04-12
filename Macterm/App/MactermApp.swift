import AppKit
import Sparkle
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
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        setAppIcon()
        _ = GhosttyApp.shared
        _ = QuickTerminalService.shared
        installKeyMonitor()
    }

    func applicationWillTerminate(_: Notification) {
        onTerminate?()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event) == true ? nil : event
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let appState else { return false }

        if HotkeyCaptureState.shared.isCapturing {
            return false
        }

        if HotkeyRegistry.matches(event, action: .recentTab) {
            guard let projectStore else { return false }
            appState.selectNextGlobalTab(projects: projectStore.projects)
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

        if HotkeyRegistry.matches(event, action: .nextTab) {
            guard let projectID = appState.activeProjectID else { return false }
            appState.selectNextTab(projectID: projectID)
            return true
        }

        if HotkeyRegistry.matches(event, action: .previousTab) {
            guard let projectID = appState.activeProjectID else { return false }
            appState.selectPreviousTab(projectID: projectID)
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

    @MainActor
    private func setAppIcon() {
        guard let url = Bundle.appResources.url(forResource: "AppIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url)
        else { return }
        image.size = NSSize(width: 512, height: 512)
        NSApp.applicationIconImage = image
    }
}
