import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ExtensionAutoUpdater")

/// Settings → Extensions → Update extensions automatically
/// (`Preferences.autoUpdateExtensions`, off by default).
///
/// It applies only the updates that the card would apply with no question
/// (`ExtensionGalleryItem.Update.available`): copies that the user did not
/// change, with a record of the install. A copy that the user changed, or
/// a copy with no record, waits for a click on its card, as before. So an
/// automatic update never discards changes of the user's own.
///
/// It reads the repository at launch, once a day after that, and at once
/// when the user turns the setting on. This is the one read of the
/// repository outside Settings → Extensions, and only when the setting is
/// on. Each update moves the old folder to the Trash, as a click does, and
/// a toast names what changed.
@MainActor
final class ExtensionAutoUpdater {
    static let interval: Duration = .seconds(24 * 60 * 60)

    private let registry: PaletteRegistry
    private let store: CustomPaletteStore
    private let isEnabled: () -> Bool
    private let announce: ([String]) -> Void
    private var loop: Task<Void, Never>?
    private var isRunning = false

    init(
        registry: PaletteRegistry,
        store: CustomPaletteStore,
        isEnabled: @escaping () -> Bool = { Preferences.shared.autoUpdateExtensions },
        announce: @escaping ([String]) -> Void
    ) {
        self.registry = registry
        self.store = store
        self.isEnabled = isEnabled
        self.announce = announce
    }

    /// The updates to apply with no question: one for each installed
    /// extension whose card offers `.available`.
    static func pending(
        installed: [CustomPaletteStore.InstalledExtension],
        registry: [PaletteRegistry.Entry]
    ) -> [PaletteRegistry.Entry] {
        let byID = Dictionary(registry.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return installed.compactMap { installed in
            guard case let .available(entry)? = ExtensionGalleryItem.installed(installed, registry: byID[installed.id]).update,
                  entry.failure == nil
            else { return nil }
            return entry
        }
    }

    /// Runs `runOnce` now and then every `interval`, until `stop`.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runOnce()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Reads the repository and applies each pending update, when the
    /// setting is on. Returns the names of the extensions that it updated.
    @discardableResult
    func runOnce() async -> [String] {
        guard isEnabled(), !isRunning else { return [] }
        isRunning = true
        defer { isRunning = false }
        await registry.refreshAndWait()
        guard case .loaded = registry.state else { return [] }
        registry.adoptUnrecordedInstalls(in: store)
        store.reloadIfChanged()
        var updated: [String] = []
        for entry in Self.pending(installed: store.extensions, registry: registry.entries) {
            do {
                try await registry.update(entry, into: store)
                updated.append(entry.name)
                logger.info("updated extension \(entry.id, privacy: .public)")
            } catch {
                logger.error("cannot update extension \(entry.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if !updated.isEmpty { announce(updated) }
        return updated
    }
}
