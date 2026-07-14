import Combine
import Sparkle
import SwiftUI

/// Thin wrapper around `SPUStandardUpdaterController` that exposes the
/// observable bits SwiftUI views need.
///
/// We ship Sparkle with an EdDSA public key baked into `Info.plist`; updates
/// are verified against that key regardless of macOS code-signing state, so
/// auto-update works even though the app is only ad-hoc signed. Sparkle
/// downloads updates via its own networking path, so installed updates do
/// not pick up the `com.apple.quarantine` attribute and launch cleanly
/// without `xattr -cr`.
/// `@Observable` (not `ObservableObject`/`@Published`) to match the project's
/// Observation convention. The Sparkle KVO/delegate bridge below writes into
/// plain observable `var`s, so nothing forces the legacy stack here.
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    @ObservationIgnored
    private let controller: SPUStandardUpdaterController
    @ObservationIgnored
    private let updaterDelegate = UpdaterDelegate()
    @ObservationIgnored
    private let userDriverDelegate = UserDriverDelegate()

    /// Exposes `canCheckForUpdates` for menu/UI disabled state.
    var canCheckForUpdates = false

    /// `true` once Sparkle has found a valid update for the current version.
    /// Flips back to `false` after the user installs, skips, or dismisses it.
    var updateAvailable = false

    @ObservationIgnored
    private var cancellable: AnyCancellable?

    private init() {
        // In debug builds Sparkle can't verify the unsigned dev binary against
        // the production EdDSA key, so it pops an "Unable to Check For
        // Updates" dialog on every launch. Start the controller without
        // kicking off update checks; release builds still auto-check.
        //
        // Benchmark mode is a Release build with the placeholder key
        // (scripts/bench.sh builds without SPARKLE_ED_PUBLIC_KEY), so the
        // updater fails to start and its app-modal alert blocks the run
        // loop at launch — on CI nobody can click OK.
        let startUpdater: Bool = {
            #if DEBUG
            return false
            #else
            return !BenchmarkControl.isEnabled
            #endif
        }()

        // Construct the controller WITHOUT starting the updater, so we can wire
        // the delegate callbacks before any check can fire. Referencing `self`
        // in a closure requires all stored properties initialized first, so the
        // controller must exist before the closures — but `startingUpdater:
        // false` means it won't invoke a delegate yet. We start it explicitly
        // below, after the closures are set, so a scheduled check on a release
        // build can't fire an update-found signal before its closure exists.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: userDriverDelegate
        )
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }

        // `didFindValidUpdate` only fires for *user-initiated* checks; scheduled
        // background checks route through the user-driver delegate — wire both.
        updaterDelegate.onUpdateFound = { [weak self] in self?.updateAvailable = true }
        updaterDelegate.onUpdateCleared = { [weak self] in self?.updateAvailable = false }
        userDriverDelegate.onUpdateFound = { [weak self] in self?.updateAvailable = true }
        userDriverDelegate.onUpdateCleared = { [weak self] in self?.updateAvailable = false }

        // Now that callbacks are wired, actually start the updater (release,
        // non-benchmark). Debug/benchmark skip it (see `startUpdater` above).
        if startUpdater {
            controller.startUpdater()
        }
    }

    var updater: SPUUpdater { controller.updater }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }
}

/// Receives callbacks for *user-initiated* checks (the "Check for Updates…"
/// menu item / Settings button).
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var onUpdateFound: (() -> Void)?
    var onUpdateCleared: (() -> Void)?

    func updater(_: SPUUpdater, didFindValidUpdate _: SUAppcastItem) {
        DispatchQueue.main.async { self.onUpdateFound?() }
    }

    func updaterDidNotFindUpdate(_: SPUUpdater) {
        DispatchQueue.main.async { self.onUpdateCleared?() }
    }

    func updater(_: SPUUpdater, didAbortWithError _: Error) {
        DispatchQueue.main.async { self.onUpdateCleared?() }
    }
}

/// Receives callbacks for *scheduled* (background) checks. Sparkle's daily
/// auto-check runs through this path; without it, the toolbar icon would never
/// appear unless the user manually triggered a check. We opt into "gentle
/// reminders" so Sparkle defers UI to us, and we surface the update by
/// flipping the toolbar flag instead of showing a modal alert.
private final class UserDriverDelegate: NSObject, SPUStandardUserDriverDelegate, @unchecked Sendable {
    nonisolated(unsafe) var onUpdateFound: (() -> Void)?
    nonisolated(unsafe) var onUpdateCleared: (() -> Void)?

    /// Tells Sparkle we'll handle showing the update ourselves rather than
    /// letting the standard alert pop up unprompted. The `state` flag tells
    /// us when Sparkle would otherwise show its alert; the toolbar icon is
    /// our equivalent surface.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _: Bool,
        forUpdate _: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard state.stage == .notDownloaded || state.stage == .downloaded else { return }
        Task { @MainActor [weak self] in self?.onUpdateFound?() }
    }

    func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor [weak self] in self?.onUpdateCleared?() }
    }
}

/// Menu item that stays disabled while an update check is already in flight.
struct CheckForUpdatesMenuItem: View {
    /// `@Observable` singleton read directly — Observation tracks the
    /// `canCheckForUpdates` read in `body`, no `@ObservedObject` needed.
    private var updater: Updater { .shared }

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}

/// Toolbar button shown in the main window's title bar only when Sparkle has
/// found a valid update. Clicking surfaces the standard Sparkle prompt.
struct UpdateAvailableToolbarButton: View {
    private var updater: Updater { .shared }

    var body: some View {
        if updater.updateAvailable {
            Button {
                updater.checkForUpdates()
            } label: {
                Label("Update Available", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
            }
            .help("An update is available. Click to install.")
        }
    }
}
