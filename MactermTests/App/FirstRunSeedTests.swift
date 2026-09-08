import Foundation
@testable import Macterm
import Testing

/// The first-run seed: when it fires, and that its two declarations name
/// tutorial topics `macterm tutor` actually knows how to print.
@MainActor
struct FirstRunSeedTests {
    // MARK: - Decision

    @Test
    func decide_seeds_only_a_genuinely_empty_first_run() {
        #expect(FirstRunSeed.decide(
            alreadySeeded: false,
            projectCount: 0,
            pinnedRecordCount: 0,
            workspaceCount: 0,
            snapshotLoadFailed: false
        ) == .seed)
    }

    @Test
    func decide_never_reconsiders_once_recorded() {
        // The flag outranks emptiness: a user who removed every project is
        // not a new install and must not get a Home project back.
        #expect(FirstRunSeed.decide(
            alreadySeeded: true,
            projectCount: 0,
            pinnedRecordCount: 0,
            workspaceCount: 0,
            snapshotLoadFailed: false
        ) == .skip)
    }

    @Test
    func decide_skips_when_anything_already_exists() {
        for (projects, pinned, workspaces) in [(1, 0, 0), (0, 1, 0), (0, 0, 1)] {
            #expect(FirstRunSeed.decide(
                alreadySeeded: false,
                projectCount: projects,
                pinnedRecordCount: pinned,
                workspaceCount: workspaces,
                snapshotLoadFailed: false
            ) == .skip)
        }
    }

    @Test
    func decide_postpones_when_the_snapshot_failed_to_load() {
        // A failed load looks exactly like a fresh install while the user's
        // real workspaces sit unread on disk — so don't seed, and (unlike
        // `.skip`) don't record the flag either: the next good launch decides.
        #expect(FirstRunSeed.decide(
            alreadySeeded: false,
            projectCount: 0,
            pinnedRecordCount: 0,
            workspaceCount: 0,
            snapshotLoadFailed: true
        ) == .postpone)
    }

    @Test
    func decide_postpones_a_harness_run() {
        // The benchmark/e2e harness gets a throwaway $HOME and data dir, so
        // every launch looks fresh — but its UserDefaults domain is the REAL
        // one, so recording the flag there would spend the user's one first
        // run, and seeding would add panes to a measured workspace.
        #expect(FirstRunSeed.decide(
            alreadySeeded: false,
            projectCount: 0,
            pinnedRecordCount: 0,
            workspaceCount: 0,
            snapshotLoadFailed: false,
            isHarnessRun: true
        ) == .postpone)
        // The flag still outranks it, so a seeded install stays settled.
        #expect(FirstRunSeed.decide(
            alreadySeeded: true,
            projectCount: 0,
            pinnedRecordCount: 0,
            workspaceCount: 0,
            snapshotLoadFailed: false,
            isHarnessRun: true
        ) == .skip)
    }

    // MARK: - Declarations

    @Test
    func declarations_run_the_tutorial_as_bare_words() throws {
        // The `run:` is TYPED into the user's login shell, so it must stay
        // quoting-free — bare words tokenize identically in bash, zsh, fish
        // and nushell. Anything else belongs inside the app-side renderer.
        for run in try [#require(pinnedRun), #require(projectRun)] {
            #expect(run.hasPrefix(FirstRunSeed.command + " "))
            #expect(
                !run.contains(where: { "'\"\\;|&$`()<>".contains($0) }),
                "run: must carry no shell metacharacters, got \(run)"
            )
        }
    }

    @Test
    func declared_topics_are_ones_the_tutor_can_render() throws {
        // The failure mode: a renamed topic in the declarations only, which
        // would print an error into the pane the tutorial is meant to teach in.
        for run in try [#require(pinnedRun), #require(projectRun)] {
            let topic = try String(#require(run.split(separator: " ").last))
            #expect(Tutorial.Topic(rawValue: topic) != nil, "no tutorial topic named \(topic)")
        }
    }

    @Test
    func the_two_seeded_panes_teach_different_things() throws {
        // A project pane and a pinned pane exist to explain different halves
        // of the sidebar; the same topic in both would waste one of them.
        #expect(try #require(pinnedRun) != #require(projectRun))
    }

    @Test
    func the_pinned_row_is_named_and_has_no_cwd() {
        #expect(FirstRunSeed.pinnedDeclaration.name == FirstRunSeed.pinnedTabName)
        // A pinned leaf with no cwd starts at PinnedTabs.fallbackRoot (home);
        // hardcoding one would strand the row on another machine.
        #expect(pinnedLeaf?.cwd == nil)
        #expect(pinnedLeaf?.shell == nil)
    }

    // MARK: - Wiring

    @Test
    func seeding_creates_the_home_directory_project_and_the_pinned_row() throws {
        let prior = Preferences.shared.hasSeededFirstRun
        let priorActive = Preferences.shared.activeProjectID
        defer {
            Preferences.shared.hasSeededFirstRun = prior
            Preferences.shared.activeProjectID = priorActive
        }
        Preferences.shared.hasSeededFirstRun = false

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-firstrun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp.appendingPathComponent("workspaces.json")),
            projectFiles: ProjectFileStore(directoryURL: tmp.appendingPathComponent("projects", isDirectory: true))
        )
        let store = ProjectStore(fileURL: tmp.appendingPathComponent("projects.json"))

        #expect(state.seedFirstRunIfNeeded(projectStore: store))

        let project = try #require(store.projects.first)
        #expect(store.projects.count == 1)
        // The automatic name a folder-picked project would get — nothing
        // invented, so the seeded row looks like one the user added.
        #expect(project.name == FirstRunSeed.projectName)
        #expect(project.name == URL(fileURLWithPath: ProjectPath.currentHome).lastPathComponent)
        #expect(project.path == ProjectPath.currentHome)
        #expect(state.activeProjectID == project.id)
        // One tab whose pane carries the tutorial as its spawn-time command.
        let ws = try #require(state.workspaces[project.id])
        #expect(ws.tabs.count == 1)
        let pane = try #require(ws.tabs.first?.splitRoot.allPanes().first)
        #expect(pane.command == projectRun)
        // And one pinned record — unloaded, so the materialize path builds it.
        #expect(state.pinnedRecords.count == 1)
        #expect(state.pinnedRecords.first?.declaration == FirstRunSeed.pinnedDeclaration)
        #expect(state.pinnedRecords.first?.originProjectID == project.id)
        #expect(Preferences.shared.hasSeededFirstRun)

        // Idempotent: the flag alone stops a second pass.
        #expect(!state.seedFirstRunIfNeeded(projectStore: store))
        #expect(store.projects.count == 1)
        #expect(state.pinnedRecords.count == 1)
    }

    @Test
    func seeding_does_not_record_the_flag_when_the_snapshot_failed_to_load() throws {
        let prior = Preferences.shared.hasSeededFirstRun
        defer { Preferences.shared.hasSeededFirstRun = prior }
        Preferences.shared.hasSeededFirstRun = false

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-firstrun-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // A present-but-undecodable snapshot is what sets `loadFailed`.
        let snapshot = tmp.appendingPathComponent("workspaces.json")
        try Data("{ not json".utf8).write(to: snapshot)
        let store = WorkspaceStore(fileURL: snapshot)
        _ = store.load()

        let state = AppState(
            workspaceStore: store,
            projectFiles: ProjectFileStore(directoryURL: tmp.appendingPathComponent("projects", isDirectory: true))
        )
        let projects = ProjectStore(fileURL: tmp.appendingPathComponent("projects.json"))

        #expect(!state.seedFirstRunIfNeeded(projectStore: projects))
        #expect(projects.projects.isEmpty)
        #expect(!Preferences.shared.hasSeededFirstRun, "a failed load must leave the decision for the next launch")
    }

    // MARK: - Helpers

    /// Non-throwing on purpose: these are read from inside `#require` /
    /// `#expect` macro expansions, whose autoclosures can't rethrow.
    private var pinnedLeaf: LayoutPane? {
        guard case let .pane(leaf) = FirstRunSeed.pinnedDeclaration.layout else { return nil }
        return leaf
    }

    private var pinnedRun: String? { pinnedLeaf?.run }

    private var projectRun: String? {
        guard let tab = FirstRunSeed.projectLayout.tabs.first,
              case let .pane(leaf) = tab.layout
        else { return nil }
        return leaf.run
    }
}
