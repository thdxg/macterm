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

    /// Exposes `canCheckForUpdates` for menu/UI disabled state.
    @Published var canCheckForUpdates = false

    private var cancellable: AnyCancellable?

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        cancellable = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
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
