import Foundation
@testable import Macterm
import Testing

@MainActor
struct WorktreesPaletteScopeTests {
    private func makeContext(path: String = "/tmp/repo", seedProject: Bool = true) -> PaletteContext {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let storeTmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let filesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-projects-\(UUID().uuidString)", isDirectory: true)
        let state = AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp),
            projectFiles: ProjectFileStore(directoryURL: filesDir)
        )
        let store = ProjectStore(fileURL: storeTmp)
        if seedProject {
            let project = Project(name: "repo", path: path, sortOrder: 0)
            store.add(project)
            state.selectProject(project)
        }
        return PaletteContext(appState: state, projectStore: store)
    }

    private let worktrees = [
        GitWorktree(path: "/tmp/repo-main", displayPath: "../repo-main", head: .branch("main"), isMain: true),
        GitWorktree(path: "/tmp/repo/.worktrees/feat", displayPath: ".worktrees/feat", head: .branch("feature/login"), isMain: false),
        GitWorktree(path: "/tmp/repo-old", displayPath: "../repo-old", head: .detached("0123456789abcdef"), isMain: false),
    ]

    private func scope(_ list: [GitWorktree]) -> WorktreesPaletteScope {
        WorktreesPaletteScope(list: { _ in list })
    }

    @Test
    func rows_are_linked_worktrees_by_branch_over_paths_relative_to_the_root() {
        let sections = scope(worktrees).sections(for: PaletteQuery(raw: ""), context: makeContext())
        #expect(sections.map(\.header) == [nil])
        #expect(sections[0].items.map(\.title) == ["feature/login", "0123456 (detached)"], "the main worktree is left out")
        #expect(sections[0].items.map(\.subtitle) == [".worktrees/feat", "../repo-old"])
        #expect(scope(worktrees).sections(for: PaletteQuery(raw: "main"), context: makeContext()).isEmpty)
    }

    @Test
    func searching_matches_the_branch_or_the_path() {
        let context = makeContext()
        #expect(scope(worktrees).sections(for: PaletteQuery(raw: "login"), context: context).first?.items.map(\.title)
            == ["feature/login"])
        #expect(scope(worktrees).sections(for: PaletteQuery(raw: "repo-old"), context: context).first?.items.map(\.title)
            == ["0123456 (detached)"])
        #expect(scope(worktrees).sections(for: PaletteQuery(raw: "zzz"), context: context).isEmpty)
    }

    @Test
    func a_repository_with_no_other_worktree_says_so() {
        let sections = scope(Array(worktrees.prefix(1))).sections(for: PaletteQuery(raw: ""), context: makeContext())
        #expect(sections.first?.items.map(\.title) == ["No Other Worktrees"])
        #expect(sections.first?.items.first?.isEnabled == false)
    }

    @Test
    func outside_a_repository_the_command_is_unavailable_and_says_why() throws {
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-not-a-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        let context = makeContext(path: plain.path)
        let ctx = AppCommandContext(appState: context.appState, projectStore: context.projectStore)

        #expect(AppCommand.worktrees.action(in: ctx) == nil)
        #expect(AppCommand.worktrees.unavailableNotice(in: ctx) == "Project is not a git repository")
        #expect(AppCommand.worktrees.paletteDisabledHint(in: ctx) == "Project is not a git repository")
        let row = CommandSource().emptyItems(context: context)?.first { $0.title == "Worktrees" }
        #expect(row?.isEnabled == false)
    }

    @Test
    func in_a_repository_the_command_opens_its_screen() throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let context = makeContext(path: repo.path)
        let ctx = AppCommandContext(appState: context.appState, projectStore: context.projectStore)

        #expect(AppCommand.worktrees.action(in: ctx) != nil)
        #expect(AppCommand.worktrees.unavailableNotice(in: ctx) == nil)
        #expect(AppCommand.worktrees.hotkeyAction == .worktrees)
        #expect(CommandSource().emptyItems(context: context)?.first { $0.title == "Worktrees" }?.opensScope == .worktrees)
    }

    @Test
    func a_remote_project_has_no_worktrees_screen() {
        let context = makeContext(path: "devbox:~/repo")
        let ctx = AppCommandContext(appState: context.appState, projectStore: context.projectStore)
        #expect(AppCommand.worktrees.action(in: ctx) == nil)
        #expect(AppCommand.worktrees.unavailableNotice(in: ctx) == "Worktrees aren’t available for remote projects")
    }

    @Test
    func with_no_project_the_chord_stays_the_terminals() {
        let context = makeContext(seedProject: false)
        let ctx = AppCommandContext(appState: context.appState, projectStore: context.projectStore)
        #expect(AppCommand.worktrees.action(in: ctx) == nil)
        #expect(AppCommand.worktrees.unavailableNotice(in: ctx) == nil)
    }
}
