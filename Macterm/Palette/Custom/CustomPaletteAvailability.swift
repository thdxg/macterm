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

    /// Checks the palettes the root list shows, once per open.
    func check(_ palettes: [CustomPalette], context: PaletteContext) {
        guard !checked else { return }
        checked = true
        let conditions = palettes.compactMap { palette in palette.condition.map { (id: palette.id, condition: $0) } }
        guard !conditions.isEmpty else { return }
        let (environment, cwd) = CustomPaletteScope.commandContext(exports: [:], context: context)
        let runner = runner
        task = Task { @MainActor [weak self] in
            let verdicts = await CustomPaletteConditions.evaluate(
                Set(conditions.map(\.condition.command)), environment: environment, currentDirectory: cwd, runner: runner
            )
            guard let self, !Task.isCancelled else { return }
            var unavailable: [String: String] = [:]
            for (id, condition) in conditions where verdicts[condition.command] != true {
                unavailable[id] = condition.reason
            }
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
