import Foundation

/// The first-run workspace: a pinned "Welcome" tab and a project on the user's
/// home directory, each with a short tutorial printed as ordinary terminal
/// output (`macterm tutor`, the bundled CLI already on every pane's PATH).
///
/// A fresh install otherwise opens on `WelcomeView` with an empty sidebar —
/// nothing to click, and no hint that projects, tabs and pinned rows are the
/// three things the sidebar holds. Seeding one of each makes the shape of the
/// app visible, and the tutorials ride in as `run:` commands so they are plain
/// scrollback the user can read, re-run (`macterm tutor project`) or clear —
/// not chrome that has to be dismissed.
///
/// Pure by design: the decision and the two declarations are values, so the
/// side-effecting half (`AppState.seedFirstRunIfNeeded`) has nothing to test
/// but the wiring. See `AppState+FirstRun.swift`.
enum FirstRunSeed {
    /// The bundled CLI's tutorial verb. Bare words, no path and no quoting:
    /// a pane's `run:` is TYPED into the user's login shell (libghostty
    /// `initial_input`), so it must tokenize identically in bash, zsh, fish
    /// AND nushell — which plain words do and little else reliably does.
    /// `EnvironmentSetup` has already put `Resources/bin` on the pane's PATH.
    /// It also keeps the seeded `run:` in `pinned.yaml` readable for the
    /// hand-editing that file exists for.
    static let command = "macterm tutor"

    /// `$HOME`-env-first (`ProjectPath.currentHome`), like every other default
    /// root in the app, so a hermetic harness home isolates the seed.
    static var projectPath: String { ProjectPath.currentHome }

    /// The name a folder-picked project would get — the directory's own
    /// basename, exactly as `AppState.openProject` derives it. Deliberately
    /// not a friendlier label like "Home": a seeded project should be
    /// indistinguishable from one the user added, so nothing about it needs
    /// explaining or un-doing.
    static var projectName: String {
        URL(fileURLWithPath: projectPath).lastPathComponent
    }

    /// The pinned row's title. Also the `name:` of its `pinned.yaml` entry.
    static let pinnedTabName = "Welcome"

    enum Decision: Equatable {
        /// Seed the pinned tab and the home project.
        case seed
        /// Nothing to seed, and the answer can't change: record the flag so
        /// this is never reconsidered (a user who later removes every project
        /// is not a new install).
        case skip
        /// Don't seed and don't record — this launch either can't judge the
        /// state or isn't a real user's launch, so ask again next time.
        case postpone
    }

    /// Seed only a genuinely empty first run: nothing the user has, no
    /// snapshot to disagree with, and never twice.
    ///
    /// `snapshotLoadFailed` is the `postpone` case: a failed load looks
    /// exactly like a fresh install (no workspaces) while the user's real
    /// workspaces sit unread on disk, so seeding there would bolt a Home
    /// project onto a workspace that is about to come back. It is also why
    /// the flag isn't recorded — the next good launch decides properly.
    /// `isHarnessRun` is the benchmark/e2e launch (`MACTERM_BENCHMARK=1`).
    /// Those runs get a throwaway `$HOME` and data dir, so they look like a
    /// fresh install on every launch — but seeding one would add a project,
    /// a pinned row and two shells to a measured or asserted-on workspace.
    /// It `postpone`s rather than `skip`s because the flag lives in the app's
    /// UserDefaults domain, which the harness does NOT isolate: recording it
    /// there would silently spend the real user's one first run.
    static func decide(
        alreadySeeded: Bool,
        projectCount: Int,
        pinnedRecordCount: Int,
        workspaceCount: Int,
        snapshotLoadFailed: Bool,
        isHarnessRun: Bool = false
    ) -> Decision {
        if alreadySeeded { return .skip }
        if isHarnessRun { return .postpone }
        if snapshotLoadFailed { return .postpone }
        guard projectCount == 0, pinnedRecordCount == 0, workspaceCount == 0 else { return .skip }
        return .seed
    }

    /// The `run:` that prints one tutorial topic.
    static func run(_ topic: Tutorial.Topic) -> String {
        "\(command) \(topic.rawValue)"
    }

    /// The pinned tab's declaration: one plain-shell leaf whose `run:` prints
    /// the pinned-tabs tour. No `cwd:` — a pinned leaf with none starts at
    /// `PinnedTabs.fallbackRoot` (home).
    static var pinnedDeclaration: LayoutTab {
        LayoutTab(
            name: pinnedTabName,
            layout: .pane(LayoutPane(cwd: nil, run: run(.pinned), shell: nil))
        )
    }

    /// The home project's single tab. Declared rather than built by hand
    /// because `Pane.command` is `let`-bound at init: going through the
    /// reconciler is how the tutorial becomes the pane's spawn-time
    /// `initial_input` instead of text typed at a prompt that may not exist
    /// yet.
    static var projectLayout: LayoutFile {
        LayoutFile(
            name: projectName,
            tabs: [LayoutTab(layout: .pane(LayoutPane(cwd: nil, run: run(.project), shell: nil)))]
        )
    }
}
