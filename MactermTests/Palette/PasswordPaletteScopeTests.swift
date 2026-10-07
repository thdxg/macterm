import Foundation
@testable import Macterm
import Testing

@MainActor
struct PasswordPaletteScopeTests {
    private func makeContext(seedProject: Bool = true) -> PaletteContext {
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
            let project = Project(name: "proj", path: "/tmp", sortOrder: 0)
            store.add(project)
            state.selectProject(project)
        }
        return PaletteContext(appState: state, projectStore: store)
    }

    private func scope(_ entries: [PasswordEntryID]) -> PasswordPaletteScope {
        let vault = PasswordVault(store: InMemoryPasswordStore())
        for id in entries {
            vault.save("pw", for: id)
        }
        return PasswordPaletteScope(vault: vault)
    }

    private let sudo = PasswordEntryID(command: "sudo", prompt: "")
    private let prod = PasswordEntryID(command: "/usr/bin/ssh prod", prompt: "ethan@prod's password:")
    private let key = PasswordEntryID(command: nil, prompt: "Enter passphrase for key '/k':")

    @Test
    func empty_it_offers_to_add_then_lists_every_entry() {
        let sections = scope([sudo, prod, key]).sections(for: PaletteQuery(raw: ""), context: makeContext())
        #expect(sections.map(\.header) == [nil, "Saved Passwords"])
        #expect(sections[0].items.map(\.title) == ["Add Password…"])
        #expect(Set(sections[1].items.map(\.title)) == ["sudo", "ssh prod", "Enter passphrase for key '/k':"])
        let allEnabled = sections[1].items.allSatisfy(\.isEnabled)
        #expect(allEnabled)
    }

    @Test
    func with_nothing_saved_only_the_add_row_shows() {
        let sections = scope([]).sections(for: PaletteQuery(raw: "  "), context: makeContext())
        #expect(sections.map(\.header) == [nil])
    }

    @Test
    func searching_puts_matches_first_then_offers_to_add_the_text() {
        let sections = scope([sudo, prod, key]).sections(for: PaletteQuery(raw: "prod"), context: makeContext())
        #expect(sections.map(\.header) == ["Saved Passwords", "Add"])
        #expect(sections[0].items.map(\.title) == ["ssh prod"])
        #expect(sections[1].items.map(\.title) == ["Add Password for Command: prod"])
    }

    @Test
    func a_search_matches_the_prompt_too() {
        let sections = scope([sudo, prod, key]).sections(for: PaletteQuery(raw: "passphrase"), context: makeContext())
        #expect(sections.first?.items.map(\.title) == ["Enter passphrase for key '/k':"])
    }

    @Test
    func nothing_matching_still_offers_to_add() {
        let sections = scope([sudo]).sections(for: PaletteQuery(raw: "zzz"), context: makeContext())
        #expect(sections.map(\.header) == ["Add"])
    }

    @Test
    func without_a_pane_to_type_into_entries_are_muted() {
        let sections = scope([sudo]).sections(for: PaletteQuery(raw: ""), context: makeContext(seedProject: false))
        let entry = sections[1].items[0]
        #expect(!entry.isEnabled)
        #expect(entry.subtitle == "No terminal pane to type into")
        #expect(sections[0].items[0].isEnabled, "adding needs no pane")
    }

    @Test
    func the_password_manager_command_opens_its_scope_in_place() {
        let item = CommandSource().emptyItems(context: makeContext())?
            .first { $0.title == AppCommand.passwordManager.title }
        #expect(item?.opensScope == .passwords)
        #expect(AppCommand.passwordManager.paletteScope == .passwords)
        #expect(PaletteScopeID.passwords.makeScope().pill.title == "Password Manager")
    }
}
