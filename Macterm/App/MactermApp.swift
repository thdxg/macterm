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
        false
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
            appState.selectNextGlobalTab(projects: projectStore.projects)
            return true
        }

        if HotkeyRegistry.matches(event, action: .previousGlobalTab) {
            guard let projectStore else { return false }
            appState.selectPreviousGlobalTab(projects: projectStore.projects)
            return true
        }

        let paneActions: [(HotkeyAction, AppState.PaneFocusDirection)] = [
            (.focusPaneLeft, .left),
            (.focusPaneDown, .down),
            (.focusPaneUp, .up),
            (.focusPaneRight, .right),
        ]
        if let (_, dir) = paneActions.first(where: { HotkeyRegistry.matches(event, action: $0.0) }) {
            guard let projectID = appState.activeProjectID else { return false }
            appState.focusPaneInDirection(dir, projectID: projectID)
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

    private func handleQuickTerminalKeyEvent(_ event: NSEvent) -> Bool {
        let qt = QuickTerminalService.shared
        let state = qt.splitState

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Ctrl+` toggles quick terminal
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

        let paneActions: [(HotkeyAction, AppState.PaneFocusDirection)] = [
            (.focusPaneLeft, .left),
            (.focusPaneDown, .down),
            (.focusPaneUp, .up),
            (.focusPaneRight, .right),
        ]
        if let (_, dir) = paneActions.first(where: { HotkeyRegistry.matches(event, action: $0.0) }) {
            guard let focusedID = state.focusedPaneID else { return false }
            let frames = state.splitRoot.paneFrames()
            guard let focusedFrame = frames[focusedID] else { return false }
            var bestID: UUID?
            var bestDist: CGFloat = .greatestFiniteMagnitude
            for (id, frame) in frames where id != focusedID {
                guard isQTCandidate(frame, from: focusedFrame, direction: dir) else { continue }
                let dist = qtDistance(from: focusedFrame, to: frame, direction: dir)
                if dist < bestDist { bestDist = dist
                    bestID = id
                }
            }
            if let bestID { state.focusedPaneID = bestID }
            return true
        }

        return false
    }

    private func isQTCandidate(_ c: CGRect, from f: CGRect, direction: AppState.PaneFocusDirection) -> Bool {
        switch direction {
        case .left: c.midX < f.midX && c.maxY > f.minY && c.minY < f.maxY
        case .right: c.midX > f.midX && c.maxY > f.minY && c.minY < f.maxY
        case .up: c.midY < f.midY && c.maxX > f.minX && c.minX < f.maxX
        case .down: c.midY > f.midY && c.maxX > f.minX && c.minX < f.maxX
        }
    }

    private func qtDistance(from f: CGRect, to c: CGRect, direction: AppState.PaneFocusDirection) -> CGFloat {
        switch direction {
        case .left,
             .right: abs(f.midX - c.midX)
        case .up,
             .down: abs(f.midY - c.midY)
        }
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
