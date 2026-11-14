import Foundation
import notify
import os

private let logger = Logger(subsystem: appBundleID, category: "RemotePaneDriver")

/// What one remote pane does (0057, 0195): it asks `RemoteHosts` what to do,
/// and runs the answer on the pane's surface. Its states:
///
/// - running: a `PaneSession` on the host's link feeds the surface;
/// - plain: a `PlainShell`, a pty with ssh, for a host with no server;
/// - waiting: a line of Macterm's is on the screen. A wake (a login that
///   ended, a trigger of the reconnect sweep) or a key asks again;
/// - ended: the session is gone from the host. Return makes a new shell.
///
/// A lost link ends the session's reading and asks `RemoteHosts` with
/// `lost`: the pane dims and waits for a trigger. The app's backoff and
/// triggers (`AppState.reconnectDroppedRemotePanes`) own the next try.
@MainActor
final class RemotePaneDriver: PaneInputRoute {
    private enum State {
        case idle
        case waiting
        case ended
        case running(PaneSession)
        case plain(PlainShell)
        case closed
    }

    let name: String
    private let surface: SurfaceChannelHost
    private let hosts: RemoteHosts
    private var state = State.idle
    /// Tells a late answer from a current one.
    private var generation = 0
    private var wakeToken: Int32 = NOTIFY_TOKEN_INVALID
    private var earlyInput = Data()

    init(name: String, surface: SurfaceChannelHost, hosts: RemoteHosts = .shared) {
        self.name = name
        self.surface = surface
        self.hosts = hosts
    }

    func start() {
        registerWake()
        step(.ask)
    }

    func stop() {
        generation += 1
        teardown()
        state = .closed
        if wakeToken != NOTIFY_TOKEN_INVALID {
            notify_cancel(wakeToken)
            wakeToken = NOTIFY_TOKEN_INVALID
        }
    }

    // MARK: - Steps

    private func step(_ event: RemotePaneEvent) {
        generation += 1
        let mine = generation
        Task { @MainActor in
            // A pane that restores before the app has installed its state
            // waits: no panes would read as "the pane closed".
            while hosts.panes == nil {
                try? await Task.sleep(for: .milliseconds(200))
                guard mine == generation else { return }
            }
            let answer = await hosts.answer(event, session: name, panes: hosts.panes?(name) ?? [])
            guard mine == generation else { return }
            apply(answer, generation: mine)
        }
    }

    private func apply(_ answer: RemotePaneAnswer, generation mine: Int) {
        if case .closed = state { return }
        teardown()
        switch answer {
        case let .wait(message):
            if let message { surface.paneFeed(Data(Self.paneText(message).utf8)) }
            state = .waiting
        case let .ended(message):
            surface.paneFeed(Data(Self.paneText(message).utf8))
            state = .ended
        case .close:
            state = .closed
            surface.paneExited(code: nil, signal: nil)
        case let .plain(arguments, message):
            surface.paneFeed(PaneSession.resetScreen)
            if let message { surface.paneFeed(Data(Self.paneText(message).utf8)) }
            runPlain(arguments)
        case let .attach(link, create):
            attach(link: link, create: create, generation: mine)
        }
    }

    private func attach(link: RemoteServers.Link, create: String?, generation mine: Int) {
        Task { @MainActor in
            var launch: PaneSession.Launch?
            if let create {
                guard let made = await hosts.createLaunch(link: link, directory: create) else {
                    guard mine == generation else { return }
                    linkStopped()
                    return
                }
                guard mine == generation else { return }
                launch = made.launch
                if let note = made.note { surface.paneFeed(Data(Self.paneText(note).utf8)) }
            }
            let session = PaneSession(
                name: name, launch: launch, wantsForeground: true, wantsTty: true, reconnects: false,
                host: Forward(driver: self, generation: mine, surface: surface),
                connect: { link.connection }
            )
            state = .running(session)
            session.start()
            if !earlyInput.isEmpty {
                session.sendInput(earlyInput)
                earlyInput = Data()
            }
        }
    }

    private func runPlain(_ arguments: [String]) {
        let mine = generation
        let shell = PlainShell(arguments: arguments, grid: surface.paneGrid(), host: surface) { [weak self] status in
            DispatchQueue.main.async { self?.plainExited(status, generation: mine) }
        }
        if let shell {
            state = .plain(shell)
        } else {
            surface.paneFeed(Data(Self.paneText("Macterm cannot start ssh.").utf8))
            state = .waiting
        }
    }

    private func plainExited(_ status: Int32, generation mine: Int) {
        guard mine == generation, case .plain = state else { return }
        // ssh exits 255 when the connection stops: the pane waits. Any other
        // status is the shell's: the pane ends.
        let code = (status >> 8) & 0xFF
        if code == 255 {
            linkStopped()
        } else {
            state = .closed
            surface.paneExited(code: UInt8(truncatingIfNeeded: code), signal: nil)
        }
    }

    /// The connection stopped: the pane dims and waits for a trigger.
    fileprivate func linkStopped() {
        if case .closed = state { return }
        teardown()
        state = .waiting
        step(.lost)
    }

    private func teardown() {
        switch state {
        case let .running(session): session.stop()
        case let .plain(shell): shell.terminate()
        default: break
        }
        state = .idle
    }

    private func registerWake() {
        notify_register_dispatch(RemoteHosts.wakeName(for: name), &wakeToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.woke() }
        }
    }

    private func woke() {
        switch state {
        case .waiting,
             .idle: step(.ask)
        default: break
        }
    }

    // MARK: - Input

    nonisolated func sendInput(_ data: Data) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.route(data) } }
    }

    nonisolated func claim(grid: PaneGrid?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.currentRoute()?.claim(grid: grid) } }
    }

    nonisolated func sendSize(_ grid: PaneGrid?) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.currentRoute()?.sendSize(grid) } }
    }

    private func currentRoute() -> (any PaneInputRoute)? {
        switch state {
        case let .running(session): session
        case let .plain(shell): shell
        default: nil
        }
    }

    private func route(_ data: Data) {
        switch state {
        case let .running(session): session.sendInput(data)
        case let .plain(shell): shell.sendInput(data)
        case .waiting: step(.retry)
        case .ended: if data.contains(0x0D) { step(.create) }
        case .idle:
            // The `initial_input` of a layout, written while the surface
            // starts: it goes to the session when one runs.
            if earlyInput.count + data.count <= 1 << 20 { earlyInput.append(data) }
        case .closed: break
        }
    }

    /// Macterm's line, on a line of its own: each line ends with CR LF,
    /// because the screen can be in any mode.
    nonisolated static func paneText(_ message: String) -> String {
        "\r\n" + message.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n"
    }

    // MARK: - The session's host

    /// What a session of this driver reports: everything goes to the
    /// surface, and a lost link goes to the driver.
    private final class Forward: PaneSessionHost, @unchecked Sendable {
        private weak var driver: RemotePaneDriver?
        private let generation: Int
        private let surface: SurfaceChannelHost

        init(driver: RemotePaneDriver, generation: Int, surface: SurfaceChannelHost) {
            self.driver = driver
            self.generation = generation
            self.surface = surface
        }

        func paneFeed(_ data: Data) {
            surface.paneFeed(data)
        }

        func paneGrid() -> PaneGrid {
            surface.paneGrid()
        }

        func paneSnapshot(started: Bool) {
            surface.paneSnapshot(started: started)
        }

        func paneForeground(_ foreground: MactermProtocol.Foreground) {
            surface.paneForeground(foreground)
        }

        func paneTtyMode(_ mode: MactermProtocol.TtyMode) {
            surface.paneTtyMode(mode)
        }

        func paneExited(code: UInt8?, signal: UInt8?) {
            surface.paneExited(code: code, signal: signal)
        }

        func paneLinkLost() {
            let mine = generation
            DispatchQueue.main.async { [weak driver] in
                MainActor.assumeIsolated {
                    guard let driver, driver.generation == mine, case .running = driver.state else { return }
                    driver.linkStopped()
                }
            }
        }

        func paneGone() {
            paneLinkLost()
        }
    }
}
