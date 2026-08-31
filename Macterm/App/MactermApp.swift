import AppKit
import os
import SwiftUI
import UserNotifications

private let logger = Logger(subsystem: appBundleID, category: "AppDelegate")

@main
struct MactermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    var appDelegate
    @State
    private var appState = AppState()
    @State
    private var projectStore = ProjectStore()

    init() {
        // Must precede any scene construction: SwiftUI can touch
        // `GhosttyApp.shared` while building views, and every environment
        // mutation has to land before `ghostty_init` captures environ.
        // See EnvironmentSetup for the full contract.
        EnvironmentSetup.runOnce()
        // Faster tooltips app-wide (macOS defaults to ~1.5s before a .help
        // tooltip appears). AppKit reads this knob only from the standard
        // defaults domain, so the Preferences seam can't carry it; register()
        // puts it in the volatile registration domain — never persisted, and
        // a user-set value in any real domain still wins — which is why this
        // doesn't breach the "never UserDefaults.standard in app code" rule.
        // It must run THIS early: the tooltip machinery can initialize with
        // the first window, which precedes applicationDidFinishLaunching on
        // some launches (see the didBecomeMain note on AppDelegate).
        // Hold a key down in a terminal and macOS's press-and-hold accent
        // overlay ("é è ê…") steals the repeat, which is wrong in every TUI
        // that binds a held key to motion — hjkl in helix/vim being the case
        // that gets reported. Terminals want key repeat, not diacritics.
        // Ghostty registers exactly this key, which is why the same ghostty
        // config behaves differently there: the knob is an AppKit default in
        // OUR process, not anything the config pipeline can carry.
        // Registration domain again (see above): a user who genuinely wants
        // the overlay keeps it via `defaults write -g ApplePressAndHoldEnabled
        // true`, since NSGlobalDomain is searched ahead of registration.
        UserDefaults.standard.register(defaults: [
            "NSInitialToolTipDelay": 350,
            "ApplePressAndHoldEnabled": false,
        ])
    }

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
                    "Close running processes?",
                    isPresented: Binding(
                        get: { appState.pendingCloseTab != nil },
                        set: { if !$0 { appState.cancelPendingCloseTab() } }
                    )
                ) {
                    Button("Cancel", role: .cancel) {
                        appState.cancelPendingCloseTab()
                    }
                    Button("Close", role: .destructive) {
                        appState.confirmPendingCloseTab()
                    }
                } message: {
                    Text("A process is still running in this tab. Closing the tab ends it.")
                }
                // Every alert below that Settings also carries is gated on the
                // staging call's `DialogHost` — see the enum's doc comment: an
                // ungated binding presents in BOTH scenes, which opens the
                // settings window just to stack a duplicate dialog.
                .alert(
                    "Unload project with running processes?",
                    isPresented: Binding(
                        get: { appState.pendingUnloadProject?.host == .mainWindow },
                        set: { if !$0 { appState.cancelPendingUnloadProject() } }
                    )
                ) {
                    Button("Cancel", role: .cancel) {
                        appState.cancelPendingUnloadProject()
                    }
                    Button("Unload", role: .destructive) {
                        appState.confirmPendingUnloadProject()
                    }
                } message: {
                    Text("A process is still running in this project. Unloading stops every process in its tabs; the layout is kept.")
                }
                .alert(
                    "Remove project with running processes?",
                    isPresented: Binding(
                        get: { appState.pendingRemoveProject?.host == .mainWindow },
                        set: { if !$0 { appState.cancelPendingRemoveProject() } }
                    )
                ) {
                    Button("Cancel", role: .cancel) {
                        appState.cancelPendingRemoveProject()
                    }
                    Button("Remove", role: .destructive) {
                        appState.confirmPendingRemoveProject()
                    }
                } message: {
                    Text("A process is still running in this project. Removing it ends every process in its tabs.")
                }
                .alert(
                    "Remove items with running processes?",
                    isPresented: Binding(
                        get: { appState.pendingBulkRemove != nil },
                        set: { if !$0 { appState.cancelPendingBulkRemove() } }
                    )
                ) {
                    Button("Cancel", role: .cancel) {
                        appState.cancelPendingBulkRemove()
                    }
                    Button("Remove", role: .destructive) {
                        appState.confirmPendingBulkRemove()
                    }
                } message: {
                    Text("A process is still running in one of the selected items. Removing them ends every process in their tabs.")
                }
                .alert(
                    "Apply layout?",
                    isPresented: Binding(
                        get: { appState.pendingLayoutApply?.host == .mainWindow },
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
                .alert(
                    appState.pendingLayoutError?.title ?? "Couldn't apply layout",
                    isPresented: Binding(
                        get: { appState.pendingLayoutError?.host == .mainWindow },
                        set: { if !$0 { appState.pendingLayoutError = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {
                        appState.pendingLayoutError = nil
                    }
                } message: {
                    if let pending = appState.pendingLayoutError {
                        Text(pending.message)
                    }
                }
                .onAppear {
                    appDelegate.appState = appState
                    appDelegate.projectStore = projectStore
                    NotificationHandler.shared.appState = appState
                    // Termination persists the snapshot AND refreshes the
                    // pinned declarations (`pinned.yaml`) from live state —
                    // the moment the respawn recipes are about to matter.
                    appDelegate.onTerminate = { [appState] in appState.persistForTermination() }
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
                    appDelegate.showWindow()
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
                AppCommandMenuItem(
                    command: .copySessionID,
                    appState: appState,
                    projectStore: projectStore,
                    titleOverride: "Copy Session ID"
                )
                Divider()
                AppCommandMenuItem(command: .closePane, appState: appState, projectStore: projectStore, titleOverride: "Close Pane")
                AppCommandMenuItem(command: .closeTab, appState: appState, projectStore: projectStore, titleOverride: "Close Tab")
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
                AppCommandMenuItem(
                    command: .nextTabInProject,
                    appState: appState,
                    projectStore: projectStore,
                    titleOverride: "Next Tab in Project"
                )
                AppCommandMenuItem(
                    command: .previousTabInProject,
                    appState: appState,
                    projectStore: projectStore,
                    titleOverride: "Previous Tab in Project"
                )
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
                // The Projects pane drives real project/layout mutations, so
                // the settings window needs the same state the main window has
                // — and its own copies of the confirmation/error alerts, since
                // the ones above are attached to `MainWindow` and would fire
                // behind (or without) the settings window.
                //
                // Each copy is presented only for a dialog this pane staged
                // (`DialogHost.settings`). Without that gate the shared state
                // fires both copies, and SwiftUI opens and fronts this window
                // just to show a duplicate of a dialog the user is already
                // answering in the main window.
                .environment(appState)
                .environment(projectStore)
                .modifier(AppColorScheme())
                .alert(
                    "Unload project with running processes?",
                    isPresented: Binding(
                        get: { appState.pendingUnloadProject?.host == .settings },
                        set: { if !$0 { appState.cancelPendingUnloadProject() } }
                    )
                ) {
                    Button("Cancel", role: .cancel) {
                        appState.cancelPendingUnloadProject()
                    }
                    Button("Unload", role: .destructive) {
                        appState.confirmPendingUnloadProject()
                    }
                } message: {
                    Text("A process is still running in this project. Unloading stops every process in its tabs; the layout is kept.")
                }
                .alert(
                    "Remove project with running processes?",
                    isPresented: Binding(
                        get: { appState.pendingRemoveProject?.host == .settings },
                        set: { if !$0 { appState.cancelPendingRemoveProject() } }
                    )
                ) {
                    Button("Cancel", role: .cancel) {
                        appState.cancelPendingRemoveProject()
                    }
                    Button("Remove", role: .destructive) {
                        appState.confirmPendingRemoveProject()
                    }
                } message: {
                    Text("A process is still running in this project. Removing it ends every process in its tabs.")
                }
                .alert(
                    "Apply layout?",
                    isPresented: Binding(
                        get: { appState.pendingLayoutApply?.host == .settings },
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
                .alert(
                    appState.pendingLayoutError?.title ?? "Couldn't apply layout",
                    isPresented: Binding(
                        get: { appState.pendingLayoutError?.host == .settings },
                        set: { if !$0 { appState.pendingLayoutError = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {
                        appState.pendingLayoutError = nil
                    }
                } message: {
                    if let pending = appState.pendingLayoutError {
                        Text(pending.message)
                    }
                }
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
    func body(content: Content) -> some View {
        // Touch configVersion so SwiftUI tracks it as a dependency and
        // re-evaluates the color scheme when the resolved theme changes.
        // Read the shared @Observable singleton directly — @State bought
        // nothing here (it doesn't own the object; read-tracking comes from
        // reading `configVersion`) and misleadingly implied view-local ownership.
        // Deliberately NOT tracking `adaptiveBackgroundColor`: the app-wide
        // scheme must never follow the transient TUI tint (see
        // `MactermTheme.colorScheme`).
        _ = GhosttyApp.shared.configVersion
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
    private var reconnectObservers: [Any] = []
    private var mainAppResponder: MainAppResponder?
    private var hasInstalledResponders = false
    /// Exists from delegate init — NOT created in applicationDidFinishLaunching
    /// — because SwiftUI can run the window's onAppear (which calls
    /// `installResponders`, attaching the request handler) BEFORE
    /// applicationDidFinishLaunching on some launches. Attaching to a
    /// not-yet-started server is fine; the reverse order lost the handler and
    /// left the socket answering `starting` forever.
    private let controlServer = ControlSocketServer(socketPath: ControlSocketServer.defaultSocketPath())
    private var controlHandler: ControlHandler?

    /// Test seam: the window list the missing-window repair consults.
    var windowLister: () -> [NSWindow] = { NSApp.windows }
    /// Test seam: how a missing `WindowGroup` window is requested from SwiftUI.
    /// The real implementation is the very call AppKit makes on a foreground
    /// launch — see `repairMissingWindow`.
    var openInitialWindow: () -> Void = { _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp) }
    private var lastInitialWindowRequest: Date?

    func applicationWillFinishLaunching(_: Notification) {
        // The terminal window's identity is "the first window to become main"
        // (see reopenIfNeeded and MainAppResponder's key-window gate). That
        // observation must start HERE, not in applicationDidFinishLaunching:
        // on a LaunchServices launch (Dock, Finder, `open`) AppKit makes the
        // window main BEFORE applicationDidFinishLaunching runs, so an
        // observer installed there misses it and `mainWindow` stays nil.
        // The next window the user mains then gets adopted as "the terminal
        // window" — typically Settings — after which every hotkey gate
        // misfires (Cmd+W closes the window, Cmd+D goes dead) and
        // reopenIfNeeded re-fronts the hidden Settings window on each app
        // activation. A direct-exec launch (running the binary from a shell)
        // reverses the order, which is why the bug only surfaced sometimes.
        // No XCTest skip: the observer is inert without the rest of the
        // launch path, and AppDelegateTests drives it directly.
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window else { return }
                // Settings (and other auxiliary windows) also become main —
                // only the first window to do so is the terminal window. The
                // responder must track that same pointer; assigning `window`
                // unconditionally handed it the Settings window whenever
                // Settings was frontmost, defeating its key-window gate.
                // The first window to become main is the terminal window;
                // cache that pointer as the authoritative identity. Do NOT
                // stamp `window.identifier` — this is a SwiftUI `WindowGroup`
                // window, and forcing an identifier on it interferes with
                // SwiftUI's own window management (it can recreate the window,
                // nilling the responder's weak `mainWindow` and breaking the
                // key-window gate that guards every hotkey).
                if self.mainWindow == nil { self.mainWindow = window }
                self.mainAppResponder?.mainWindow = self.mainWindow
            }
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        // Log-only and cheap, so installed even when hosting tests (before the
        // xctest early-return below): an uncaught ObjC exception otherwise
        // kills the app with its reason redacted and no crash report.
        ExceptionReporting.install()
        // Skip the heavy launch path when the app is hosting unit tests.
        // Without this, libghostty boots, the key router installs, etc. —
        // which times out the xctest runner that just wants to load our
        // module symbols. ProcessInfo.environment is the standard way to
        // detect xctest hosting (Xcode sets this env var).
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        // MACTERM_SOCKET, PATH, and the zmx-session scrub moved to
        // EnvironmentSetup (run from MactermApp.init): environ must not be
        // mutated after ghostty_init captures it, and SwiftUI can trigger
        // GhosttyApp.shared before this method runs. Binding the socket
        // itself can stay here — only the env var needed to move. Requests
        // get a `starting` error until installResponders attaches the
        // handler.
        controlServer.start()
        UNUserNotificationCenter.current().delegate = NotificationHandler.shared
        NotificationHandler.shared.registerCategories()
        if BenchmarkControl.isEnabled {
            // Under the CI benchmark, the notification-permission alert would
            // steal key focus mid-measurement and nobody is there to answer it.
            BenchmarkControl.install()
        } else {
            NotificationHandler.shared.requestAuthorization()
        }
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

        repairMissingWindow(attempt: 0)

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

        // Reconnect dropped remote panes when the user comes back (#281).
        // System wake fires a short burst — wifi isn't up at wake, and when
        // the app is already frontmost no activation ever follows — while
        // app activation is a single sweep. Every sweep is additionally gated
        // per pane by `RemoteReconnectPolicy`, so notification churn here can
        // never turn into a retry loop against an unreachable host.
        reconnectObservers = [
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleWakeReconnectBurst() }
            },
            focusCenter.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.appState?.reconnectDroppedRemotePanes(trigger: .activate)
                }
            },
        ]
    }

    /// Seconds after wake at which the reconnect sweep runs. The first waits
    /// out wifi re-association; the later ones cover ssh clients that took
    /// longer to die (a dropped connection can sit in TCP keepalive for a
    /// while before the client exits) and the frontmost-at-wake case above.
    private static let wakeReconnectDelays: [TimeInterval] = [3, 10, 30, 75]

    private func scheduleWakeReconnectBurst() {
        for delay in Self.wakeReconnectDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.appState?.reconnectDroppedRemotePanes(trigger: .wake)
            }
        }
    }

    /// Could `window` be the terminal window?
    ///
    /// The heuristic used to be "not an `NSPanel`" — panels are the quick
    /// terminal, and everything else at launch time is the `WindowGroup`. That
    /// stopped being true once a pane could be warmed off-screen:
    /// `SurfaceIncubator`'s window is a plain, permanently invisible `NSWindow`
    /// in `NSApp.windows`, so it matched both "a window exists" and — worse —
    /// "the ordered-out terminal window", which `reopenIfNeeded` would then
    /// order in (a blank black rectangle) and cache as `mainWindow`, killing
    /// every key-window-gated hotkey for the rest of the run.
    ///
    /// Still a heuristic, not an identity: the Settings window is also a plain
    /// `NSWindow` and still matches. Identity remains the pointer
    /// `didBecomeMain` cached; this only narrows the fallback used before that
    /// pointer exists.
    static func isTerminalWindowCandidate(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && !(window is SurfaceIncubatorWindow)
    }

    /// Any window of ours that could be the terminal window.
    private func hasTerminalWindow() -> Bool {
        windowLister().contains(where: Self.isTerminalWindowCandidate)
    }

    /// Ask SwiftUI to build the `WindowGroup`'s window when AppKit's launch
    /// path never did (issue #241).
    ///
    /// SwiftUI creates that first window only while AppKit handles the launch
    /// `aevt/oapp` event's open-untitled step, and AppKit skips the step when
    /// the app is launched without being brought to the front — which is
    /// exactly how macOS relaunches apps for "Reopen windows when logging back
    /// in". Reproduced with `open -g -n` (the log shows
    /// `BringFrontModifier … dontMakeFrontmost=1`, then the `aevt/oapp` handler
    /// running but never reaching window creation, vs. a foreground launch
    /// where it does).
    ///
    /// The result is a running app with **zero** windows: the Dock shows a
    /// running dot, but there is nothing hidden for `reopenIfNeeded`, "Show
    /// Window", or a Dock click to re-front — activating the app afterwards
    /// does NOT make AppKit reconsider — so the user has to quit and relaunch.
    /// It also means `MainWindow.onAppear` never runs, so the app has no
    /// responders and its control socket answers `starting` forever.
    ///
    /// The repair is the same call AppKit itself makes on a foreground launch,
    /// which was the one candidate that actually produced a window in that
    /// state (`NSApp.activate(ignoringOtherApps:)` did not). It is deliberately
    /// gated on there being no window at all, and deliberately delayed: AppKit
    /// decides during launch-event handling, so a window that hasn't appeared
    /// within the deadline is never coming, while firing early could add a
    /// second window to a deliberately single-window app.
    func repairMissingWindow(attempt: Int) {
        guard !hasTerminalWindow() else { return }
        guard attempt >= Self.windowRepairAttempts else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.windowRepairInterval) { [weak self] in
                self?.repairMissingWindow(attempt: attempt + 1)
            }
            return
        }
        logger.warning("no window after launch — asking SwiftUI to open one")
        requestInitialWindow()
    }

    private static let windowRepairInterval: TimeInterval = 0.25
    /// Internal so the tests can jump straight to the deadline.
    static let windowRepairAttempts = 12
    private static let initialWindowRequestCooldown: TimeInterval = 5

    /// Single funnel for "build the missing window", debounced: SwiftUI's
    /// window appears a run-loop turn or two after the request, so two callers
    /// racing (the launch repair and a Dock click landing just before it)
    /// would otherwise open two windows in a deliberately single-window app.
    private func requestInitialWindow() {
        if let last = lastInitialWindowRequest,
           Date().timeIntervalSince(last) < Self.initialWindowRequestCooldown
        {
            return
        }
        lastInitialWindowRequest = Date()
        openInitialWindow()
    }

    /// Front the terminal window for an explicit user request ("Show Window"),
    /// opening it first if the launch never produced one.
    func showWindow() {
        if let window = mainWindow ?? windowLister().first(where: Self.isTerminalWindowCandidate) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        requestInitialWindow()
    }

    /// Called from MactermApp.onAppear once the state objects exist. Registers
    /// responders in priority order: palette first, quick terminal second,
    /// main app last.
    func installResponders(appState: AppState, projectStore: ProjectStore) {
        guard !hasInstalledResponders else { return }
        hasInstalledResponders = true
        if BenchmarkControl.isEnabled {
            BenchmarkControl.connect(appState: appState, projectStore: projectStore)
        }
        let handler = ControlHandler(appState: appState, projectStore: projectStore)
        controlHandler = handler
        controlServer.attach { raw in await handler.handle(raw) }
        KeyRouter.shared.register(PaletteResponder(appState: appState))
        KeyRouter.shared.register(QuickTerminalResponder())
        let mainResponder = MainAppResponder(appState: appState, projectStore: projectStore)
        mainResponder.mainWindow = mainWindow
        mainAppResponder = mainResponder
        KeyRouter.shared.register(mainResponder)
        // Tab-cycle commit on Ctrl-release, and Cmd+digit run end on
        // Cmd-release (so the next digit addresses a tab rather than
        // extending the number the last one built).
        KeyRouter.shared.registerFlagsHandler { [weak appState, weak mainResponder] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !flags.contains(.command) { mainResponder?.endTabIndexChord() }
            guard let appState, appState.isTabCycling else { return }
            if !flags.contains(.control),
               let projectID = appState.activeProjectID
            {
                appState.commitTabCycle(projectID: projectID)
            }
        }
    }

    func applicationWillTerminate(_: Notification) {
        controlServer.stop()
        onTerminate?()
        // Quit is always a DETACH: workspace panes' sessions survive and
        // reattach on relaunch (the snapshot saved by onTerminate carries each
        // pane's session identity). Quick-terminal sessions are ephemeral —
        // never persisted — so they're the only ones killed here; leaving them
        // would only feed the next launch's reaper. Those are local, so no
        // remote sweep is needed. The kills block briefly so they land before
        // the process exits (a detached Task is never scheduled during
        // teardown), bounded by ZmxClient's timeouts.
        let names = QuickTerminalService.shared.splitState.tab.splitRoot.allPanes().map(\.sessionName)
        (appState?.zmx ?? .live).killSessionsBlocking(names)
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        // Silent quit when persistence is active: workspace sessions detach
        // and reattach next launch, so there's nothing to confirm for them.
        // The full prompt returns only when zmx is unavailable (sessions
        // genuinely die with the app). Quick-terminal sessions are ephemeral
        // and die on every quit, so a busy quick-terminal pane still confirms
        // even on a silent quit — the confirmation follows the destruction.
        let persistenceActive = (appState?.zmx ?? .live).isBundled()
        if persistenceActive {
            let qtRows = collectQuickTerminalRows()
            if qtRows.isEmpty || QuitConfirmation.runModal(rows: qtRows) {
                AppTerminationState.isTerminating = true
                return .terminateNow
            }
            return .terminateCancel
        }

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
            let projectName = ws.projectID == PinnedTabs.projectID
                ? PinnedTabs.displayName
                : (project?.name ?? "Project")
            for tab in ws.tabs {
                for pane in tab.splitRoot.allPanes() where pane.needsConfirmClose {
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

        rows += collectQuickTerminalRows()
        return rows
    }

    /// Quick-terminal panes with a running foreground process. Split out
    /// because a silent (persistence-active) quit still confirms these: the
    /// quick terminal's sessions are ephemeral and die on every quit.
    private func collectQuickTerminalRows() -> [RunningProcessRow] {
        var rows: [RunningProcessRow] = []
        let qtTab = QuickTerminalService.shared.splitState.tab
        for pane in qtTab.splitRoot.allPanes() where pane.needsConfirmClose {
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

    /// Bring our (possibly ordered-out) terminal window back. The terminal
    /// window is identified by the pointer `didBecomeMain` cached (the first
    /// window to become main) — NOT by `isTerminalWindowCandidate`, which also
    /// matches the Settings window (a plain NSWindow). We never stamp a SwiftUI
    /// window's identifier (that breaks its window management), so identity is
    /// the cached pointer; the candidate heuristic is only a last-resort
    /// fallback for before the terminal window has ever become main.
    func reopenIfNeeded() {
        // If the terminal window is already visible, nothing to do.
        if let cached = mainWindow, cached.isVisible {
            return
        }
        // No cached pointer yet (terminal window never became main): fall back
        // to a visibility check over the candidates to avoid re-fronting
        // needlessly.
        if mainWindow == nil, windowLister().contains(where: { $0.isVisible && Self.isTerminalWindowCandidate($0) }) {
            return
        }

        // Prefer the cached terminal window; only if it's absent fall back to
        // the first hidden candidate. The incubator's window is excluded there
        // by construction: it is permanently invisible, so it would otherwise
        // always be a match, and ordering it in shows a blank black rectangle.
        let target = mainWindow ?? windowLister().first { !$0.isVisible && Self.isTerminalWindowCandidate($0) }
        guard let target else {
            // Nothing to re-front. A launch that never brought the app forward
            // leaves SwiftUI with no window at all (see repairMissingWindow),
            // and this activation is the user asking for it — so build it now
            // rather than leaving them with a windowless app.
            requestInitialWindow()
            return
        }
        target.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Adopt a freshly-discovered window as the cached pointer only when we
        // had none — never overwrite a live cached terminal window with some
        // other discovered window (e.g. Settings).
        if mainWindow == nil {
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
