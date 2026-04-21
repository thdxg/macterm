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
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController
    private let delegate = UpdaterDelegate()

    /// Exposes `canCheckForUpdates` for menu/UI disabled state.
    @Published var canCheckForUpdates = false

    /// `true` once Sparkle has found a valid update for the current version.
    /// Flips back to `false` after the user installs, skips, or dismisses it.
    @Published var updateAvailable = false

    private var cancellable: AnyCancellable?

    private init() {
        let delegate = delegate
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
        delegate.onUpdateFound = { [weak self] in
            self?.updateAvailable = true
        }
        delegate.onUpdateCleared = { [weak self] in
            self?.updateAvailable = false
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

/// Bridges Sparkle delegate callbacks into closures Updater can observe.
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

    func updater(_: SPUUpdater, didFinishUpdateCycleFor _: SPUUpdateCheck, error _: Error?) {
        // Left blank intentionally — state is driven by the more specific
        // didFindValidUpdate / didNotFindUpdate callbacks above.
    }
}

/// Menu item that stays disabled while an update check is already in flight.
struct CheckForUpdatesMenuItem: View {
    @ObservedObject var updater: Updater = .shared

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
    @ObservedObject var updater: Updater = .shared

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
