import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "BenchmarkControl")

/// CI-only remote control for the window-state benchmark
/// (`.github/workflows/benchmark.yml` → `scripts/benchmark.py`).
///
/// When the app is launched with `MACTERM_BENCHMARK=1` it listens for Darwin
/// notifications (posted from a shell with `notifyutil -p <name>`) and drives
/// itself through the benchmarked window states. Darwin notifications need no
/// TCC grant — unlike AppleScript/System Events or synthetic key events — so a
/// headless CI runner can script the app without touching the SIP-protected
/// permission database.
@MainActor
enum BenchmarkControl {
    static let isEnabled = ProcessInfo.processInfo.environment["MACTERM_BENCHMARK"] == "1"

    // Strong references are fine here: both objects live for the app's
    // lifetime, and benchmark mode never releases them.
    private static var appState: AppState?
    private static var projectStore: ProjectStore?

    /// An `openProject` command can arrive before `connect`: SwiftUI only
    /// creates the window (whose `onAppear` wires the state objects) once
    /// macOS grants activation, and the harness polls the command until
    /// then. Park it instead of dropping it.
    private static var pendingOpenProject = false

    /// Called by `AppDelegate.installResponders` once the state objects exist.
    static func connect(appState: AppState, projectStore: ProjectStore) {
        self.appState = appState
        self.projectStore = projectStore
        if pendingOpenProject {
            pendingOpenProject = false
            openProject()
        }
    }

    private static let notificationPrefix = "com.thdxg.macterm.bench."

    /// Held for the app's lifetime in benchmark mode. Without it, App Nap
    /// suspends the backgrounded/occluded app — queued Darwin notifications
    /// go undelivered and, on a busy desktop, the window never even appears.
    /// It also makes the numbers measure what we care about: the app's own
    /// timer/render/wakeup behavior, not the OS's nap throttling masking a
    /// regression.
    private static var activity: NSObjectProtocol?

    private enum Command: String, CaseIterable {
        case openProject = "open-project"
        case activate
        case minimize
        case restore
    }

    static func install() {
        guard isEnabled else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "window-state benchmark"
        )
        nudgeActivationUntilWindowExists()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for command in Command.allCases {
            CFNotificationCenterAddObserver(
                center,
                nil,
                { _, _, name, _, _ in
                    guard let name else { return }
                    let raw = name.rawValue as String
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { BenchmarkControl.handle(raw) }
                    }
                },
                (notificationPrefix + command.rawValue) as CFString,
                nil,
                .deliverImmediately
            )
        }
        logger.info("benchmark control listening (MACTERM_BENCHMARK=1)")
    }

    /// SwiftUI doesn't create the WindowGroup window until the app becomes
    /// active, and a single post-launch activation request can be denied
    /// (cooperative activation) or arrive before the session is ready on a
    /// fresh CI runner. Re-request every second until the window exists.
    private static func nudgeActivationUntilWindowExists(attempt: Int = 0) {
        if mainWindow != nil {
            logger.info("bench window exists after \(attempt, privacy: .public) activation nudges")
            return
        }
        guard attempt < 120 else {
            logger.error("bench window never appeared; giving up activation nudges")
            return
        }
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            nudgeActivationUntilWindowExists(attempt: attempt + 1)
        }
    }

    private static func handle(_ rawName: String) {
        guard let command = Command(rawValue: String(rawName.dropFirst(notificationPrefix.count))) else { return }
        logger.info("bench command: \(command.rawValue, privacy: .public)")
        switch command {
        case .openProject:
            openProject()
        case .activate:
            NSApp.activate()
            mainWindow?.makeKeyAndOrderFront(nil)
        case .minimize:
            mainWindow?.miniaturize(nil)
        case .restore:
            mainWindow?.deminiaturize(nil)
            NSApp.activate()
            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    /// Select (creating if needed) a project at `MACTERM_BENCHMARK_DIR` (or
    /// `$HOME`) so the window hosts a live terminal pane. A fresh CI runner
    /// otherwise sits on the WelcomeView, and the benchmark would measure an
    /// app with no surface, no shell, and no foreground-process poll.
    private static func openProject() {
        guard let appState, let projectStore else {
            logger.info("bench open-project queued until state objects exist")
            pendingOpenProject = true
            return
        }
        let path = ProcessInfo.processInfo.environment["MACTERM_BENCHMARK_DIR"] ?? NSHomeDirectory()
        let project = projectStore.findOrCreate(name: "Benchmark", path: path)
        appState.selectProject(project)
    }

    /// Same filter as `AppDelegate.reopenIfNeeded`: the single main window is
    /// the only non-panel window (panels: quick terminal, settings).
    private static var mainWindow: NSWindow? {
        NSApp.windows.first { !($0 is NSPanel) }
    }
}
