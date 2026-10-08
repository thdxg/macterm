import Foundation

/// The palette-level `when:` verdicts for one open of the command palette:
/// which custom palettes can't be used now, and why. Each palette with a
/// `when:` is checked once when the root list first shows, in the
/// background — identical commands once — and its row is usable until its
/// check fails. Held by the palette panel, so it is per window and per open:
/// closing the palette forgets it, and the next open checks again.
@MainActor @Observable
final class CustomPaletteAvailability {
    /// Palette id → the reason its row shows, for each whose check failed.
    private(set) var unavailable: [String: String] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var checked = false
    @ObservationIgnored private let runner: CustomPaletteCommandRunner

    init(runner: @escaping CustomPaletteCommandRunner = CustomPaletteRunner.checkCondition) {
        self.runner = runner
    }

    /// Checks the palettes the root list shows, once per open. Palettes
    /// sharing a command and an environment run it once; an installed
    /// extension's check sees its own folder (`MACTERM_EXTENSION_DIR`), so
    /// extensions are checked in their own groups.
    func check(_ palettes: [CustomPalette], context: PaletteContext) {
        guard !checked else { return }
        checked = true
        let conditions = palettes.compactMap { palette in palette.condition.map { (id: palette.id, condition: $0) } }
        guard !conditions.isEmpty else { return }
        let groups = Dictionary(grouping: conditions) { CustomPaletteScope.extensionExports(paletteID: $0.id, context: context) }
            .map { exports, members in
                (members: members, context: CustomPaletteScope.commandContext(exports: exports, context: context))
            }
        let runner = runner
        task = Task { @MainActor [weak self] in
            var unavailable: [String: String] = [:]
            for group in groups {
                let (environment, cwd) = group.context
                let verdicts = await CustomPaletteConditions.evaluate(
                    Set(group.members.map(\.condition.command)), environment: environment, currentDirectory: cwd, runner: runner
                )
                for (id, condition) in group.members where verdicts[condition.command] != true {
                    unavailable[id] = condition.reason
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.unavailable = unavailable
        }
    }

    /// The palette closed: forget, and check again next time.
    func reset() {
        task?.cancel()
        task = nil
        checked = false
        unavailable = [:]
    }
}
