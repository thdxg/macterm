import Foundation
@testable import Macterm
import Testing

/// The screen model shared by every palette scope: frames, their lifecycle,
/// and the loading and failure states a slow listing reports.
@MainActor
struct PaletteScopeTests {
    /// A scope whose listing takes time and can fail — the shape a custom
    /// palette's command-backed screen has, driven by hand here.
    final class ListingScope: PaletteScope {
        let placeholder = "Search…"
        var loading: PaletteLoading?
        var failure: PaletteFailure?
        var rows: [String] = []
        var activations = 0
        var deactivations = 0
        var retries = 0
        private var onChange: (@MainActor () -> Void)?

        func sections(for query: PaletteQuery, context _: PaletteContext) -> [PaletteSection] {
            let items = rows
                .filter { query.isEmpty || Search.matches(query.trimmed, in: [$0]) }
                .map { PaletteItem(id: $0, title: $0, action: {}) }
            return items.isEmpty ? [] : [PaletteSection(header: nil, items: items)]
        }

        func activate(context _: PaletteContext, onChange: @escaping @MainActor () -> Void) {
            self.onChange = onChange
            activations += 1
            guard loading == nil, rows.isEmpty else { return }
            loading = PaletteLoading(message: "Listing namespaces…")
            onChange()
        }

        func deactivate() {
            deactivations += 1
        }

        func retry() {
            retries += 1
            failure = nil
            loading = PaletteLoading(message: "Listing namespaces…")
            onChange?()
        }

        func finish(rows: [String]) {
            loading = nil
            self.rows = rows
            onChange?()
        }

        func fail(_ detail: String) {
            loading = nil
            failure = PaletteFailure(title: "Couldn't list namespaces", detail: detail)
            onChange?()
        }
    }

    private func makeContext() -> PaletteContext {
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
        return PaletteContext(appState: state, projectStore: ProjectStore(fileURL: storeTmp))
    }

    @Test
    func built_in_scopes_neither_load_nor_fail() {
        for id in PaletteScopeID.builtIn {
            let frame = PaletteFrame(id)
            #expect(frame.scope.loading == nil)
            #expect(frame.scope.failure == nil)
            #expect(frame.pill == id.pill)
            frame.scope.retry()
            frame.scope.activate(context: makeContext()) {}
            frame.scope.deactivate()
        }
    }

    @Test
    func a_slow_listing_reports_loading_then_its_rows_or_its_failure() {
        let scope = ListingScope()
        let context = makeContext()
        var redraws = 0
        scope.activate(context: context) { redraws += 1 }
        #expect(scope.loading?.message == "Listing namespaces…")
        #expect(scope.sections(for: PaletteQuery(raw: ""), context: context).isEmpty, "nothing to show yet")
        #expect(redraws == 1)

        // Told again when its frame returns to the top: nothing restarts.
        scope.activate(context: context) { redraws += 1 }
        #expect(redraws == 1)

        scope.fail("kubectl: command not found")
        #expect(scope.loading == nil)
        #expect(scope.failure == PaletteFailure(title: "Couldn't list namespaces", detail: "kubectl: command not found"))
        #expect(redraws == 2)

        scope.retry()
        #expect(scope.failure == nil, "a retry clears the failure while it runs")
        #expect(scope.loading != nil)

        scope.finish(rows: ["default", "kube-system", "prod"])
        #expect(scope.loading == nil)
        let all = scope.sections(for: PaletteQuery(raw: ""), context: context).flatMap(\.items).map(\.title)
        #expect(all == ["default", "kube-system", "prod"])
        let some = scope.sections(for: PaletteQuery(raw: "pro"), context: context).flatMap(\.items).map(\.title)
        #expect(some == ["prod"], "keystrokes filter the cached rows; nothing is listed again")
        #expect(redraws == 4)
    }

    @Test
    func a_frame_leaving_the_stack_deactivates_its_scope_once() {
        let window = WindowState()
        let scopes = (0 ..< 3).map { _ in ListingScope() }
        for scope in scopes {
            window.pushPaletteFrame(PaletteFrame(.worktrees, scope: scope))
        }

        window.popPaletteFrame()
        #expect(scopes.map(\.deactivations) == [0, 0, 1])

        window.popPaletteFrames(above: 0)
        #expect(scopes.map(\.deactivations) == [0, 1, 1], "a pill click ends every frame above it")

        window.showPaletteScope(.passwords)
        #expect(scopes.map(\.deactivations) == [1, 1, 1], "a chord's screen replaces the stack")
        #expect(window.paletteStack.map(\.scopeID) == [.passwords])

        window.resetPaletteStack()
        #expect(window.paletteStack.isEmpty)
        #expect(scopes.map(\.deactivations) == [1, 1, 1], "a frame already gone is not told twice")
    }

    @Test
    func every_screen_is_a_palettes_command_with_a_chord_of_its_own() {
        for scope in PaletteScopeID.builtIn {
            #expect(scope.command?.paletteScope == scope)
            #expect(scope.command?.category == .palettes)
            #expect(scope.command?.hotkeyAction != nil, "\(scope) must be bindable in Settings → Keymaps")
            #expect(scope.command?.title == scope.pill.title)
        }
        #expect(AppCommand.toggleCommandPalette.category == .palettes, "the palette's own chord sits with the screens' in Keymaps")
        #expect(AppCommand.allCases.first?.category == .palettes, "palettes are the first section of the palette's default state")
    }

    @Test
    func a_screen_turned_off_in_settings_leaves_the_palette_and_its_chord_says_so() {
        let prior = Preferences.shared.disabledPaletteIDs
        defer { Preferences.shared.disabledPaletteIDs = prior }
        let context = makeContext()
        let ctx = AppCommandContext(appState: context.appState, projectStore: context.projectStore)
        let rows = { CommandSource().emptyItems(context: context)?.map(\.title) ?? [] }

        #expect(rows().contains("Password Manager"))
        #expect(AppCommand.passwordManager.action(in: ctx) != nil)

        Preferences.shared.setPalette(PaletteScopeID.passwords.settingsID, enabled: false)
        #expect(!PaletteScopeID.passwords.isEnabled)
        #expect(!rows().contains("Password Manager"), "gone, not muted")
        #expect(AppCommand.passwordManager.action(in: ctx) == nil, "its menu item disables")
        #expect(AppCommand.passwordManager.paletteDisabledHint(in: ctx) == nil)
        #expect(AppCommand.passwordManager.unavailableNotice(in: ctx) == "Password Manager is turned off in Settings → Palettes")
        #expect(PaletteScopeID.worktrees.isEnabled, "the other screen is untouched")

        Preferences.shared.setPalette(PaletteScopeID.passwords.settingsID, enabled: true)
        #expect(rows().contains("Password Manager"))
    }

    @Test
    func an_alt_action_and_a_warning_survive_rescoring() {
        var ran = ""
        let item = PaletteItem(
            title: "README.md",
            warning: "careful",
            alt: PaletteAltAction(title: "Open with Default App") { ran = "alt" },
            action: { ran = "primary" }
        )
        let rescored = item.with(score: 3)
        #expect(rescored.alt?.title == "Open with Default App")
        #expect(rescored.warning == "careful")
        rescored.alt?.action()
        #expect(ran == "alt")
        rescored.action()
        #expect(ran == "primary")
        #expect(PaletteItem(title: "Split Right", action: {}).alt == nil)
    }

    @Test
    func a_row_that_opens_a_screen_wears_its_glyph_and_keeps_it_when_rescored() {
        let item = PaletteItem(title: "Worktrees", opensScope: .worktrees, action: {})
        #expect(item.icon == "arrow.triangle.branch")
        #expect(item.with(score: 7).icon == "arrow.triangle.branch")
        #expect(PaletteItem(title: "Pods", icon: "shippingbox", action: {}).icon == "shippingbox")
        #expect(PaletteItem(title: "Split Right", action: {}).icon == nil, "a thing to do has no glyph")
    }
}
