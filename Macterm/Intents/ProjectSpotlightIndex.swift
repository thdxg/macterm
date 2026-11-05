import AppIntents
import CoreSpotlight
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ProjectSpotlightIndex")

/// Puts the projects in Spotlight as `MactermProjectEntity` items, so that
/// Spotlight and Siri find a project by its name or its folder. A click on a
/// result runs `OpenMactermProjectIntent`.
///
/// The index is the whole project list, written again after each save of
/// `projects.json` (`ProjectStore.onSave`). Projects are few, so a full
/// rewrite is cheap, and it removes the items of deleted projects with no
/// bookkeeping. The pinned and scratch workspaces are not projects in the
/// store, so they are not indexed.
@MainActor
final class ProjectSpotlightIndex {
    static let shared = ProjectSpotlightIndex()

    /// The wait after a save before the index is written. A drag that
    /// reorders the sidebar saves once for each move.
    static let debounce = Duration.milliseconds(500)

    private var pending: Task<Void, Never>?

    private init() {}

    /// True for a launch that must not write the user's Spotlight index:
    /// unit tests and the benchmark and e2e harnesses. Their projects are
    /// throwaway, and the Debug app's index is the developer's own.
    static var isHermetic: Bool {
        Preferences.isTestRun
            || BenchmarkControl.isEnabled
            || ProcessInfo.processInfo.environment["MACTERM_BENCHMARK_DATA_DIR"] != nil
    }

    /// Index the store's projects now, and again after each save.
    func attach(projectStore: ProjectStore) {
        guard !Self.isHermetic else { return }
        projectStore.onSave = { [weak self] projects in self?.update(projects) }
        update(projectStore.projects)
    }

    private func update(_ projects: [Project]) {
        guard #available(macOS 15.0, *) else { return }
        let entities = projects.map(MactermProjectEntity.init)
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            do {
                let index = CSSearchableIndex.default()
                try await index.deleteAppEntities(ofType: MactermProjectEntity.self)
                try await index.indexAppEntities(entities)
                logger.debug("indexed \(entities.count, privacy: .public) projects in Spotlight")
            } catch {
                logger.error("Spotlight index failed: \(EnglishErrorText.describe(error), privacy: .public)")
            }
        }
    }
}
