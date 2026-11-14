import Foundation
@testable import Macterm
import Testing

/// A host for a `PaneSession` that records what it is given.
final class RecordingPaneHost: PaneSessionHost, @unchecked Sendable {
    struct State {
        var screen = ""
        var exit: (code: UInt8?, signal: UInt8?)?
        var linkLost = 0
        var resets = 0
        var foreground: MactermProtocol.Foreground?
    }

    private let lock = NSLock()
    private var state = State()
    private let grid: PaneGrid

    init(grid: PaneGrid = PaneGrid(cols: 80, rows: 24)) {
        self.grid = grid
    }

    func snapshot() -> State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Polls until `condition` holds, or fails after 20 s.
    @MainActor
    func waitFor(_ condition: (State) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if condition(snapshot()) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("timed out: \(snapshot().screen.debugDescription)")
    }

    func paneFeed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if data == PaneSession.resetScreen {
            state.resets += 1
            state.screen = ""
        } else {
            state.screen += String(decoding: data, as: UTF8.self)
        }
    }

    func paneGrid() -> PaneGrid {
        grid
    }

    func paneSnapshot(started _: Bool) {}
    func paneTtyMode(_: MactermProtocol.TtyMode) {}
    func paneForeground(_ foreground: MactermProtocol.Foreground) {
        lock.lock()
        state.foreground = foreground
        lock.unlock()
    }

    func paneExited(code: UInt8?, signal: UInt8?) {
        lock.lock()
        state.exit = (code, signal)
        lock.unlock()
    }

    func paneLinkLost() {
        lock.lock()
        state.linkLost += 1
        lock.unlock()
    }

    func paneGone() {}
}
