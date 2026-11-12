import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "PaneSession")

/// The size of the pane's surface, in cells and pixels.
struct PaneGrid: Equatable {
    var cols: UInt16
    var rows: UInt16
    var widthPx: UInt32 = 0
    var heightPx: UInt32 = 0
}

/// What a `PaneSession` drives: the surface that shows the pane. The
/// callbacks come from the session's tasks, not from the main actor.
protocol PaneSessionHost: AnyObject, Sendable {
    /// Bytes for the terminal (output, or a snapshot).
    func paneFeed(_ data: Data)
    /// The surface's size now.
    func paneGrid() -> PaneGrid
    /// A snapshot of the pane starts or ends. Titles inside it are old.
    func paneSnapshot(started: Bool)
    func paneForeground(_ foreground: MactermProtocol.Foreground)
    /// The session says if this client leads (its size is the pty's).
    func paneLeadership(_ leader: Bool)
    /// The shell exited. The session ended.
    func paneExited(code: UInt8?, signal: UInt8?)
    /// The channel ended with no exit. The session tries to connect again.
    func paneLinkLost()
    /// The session did not come back. The pane has nothing to show.
    func paneGone()
}

/// One pane's session on a server: it makes the session when a `launch` is
/// given, opens a channel, attaches, and feeds the host from the channel.
/// Input, claims and sizes go back on the same channel, in order, from a
/// queue of its own, so a stalled server never blocks the caller.
///
/// A channel that ends with no exit is a lost link: the session connects
/// again (`connect` gives a connection that is up), attaches again, and the
/// snapshot that follows draws the pane over a cleared screen.
final class PaneSession: @unchecked Sendable {
    /// What a new session runs: the launch that libghostty resolved for the
    /// pane (`ghostty_launch_resolve`), or nothing for a remote pane, whose
    /// session runs the user's login shell on the host.
    struct Launch: Equatable {
        var cwd: String?
        var argv: [String]?
        var env: [String]
    }

    typealias Connect = @Sendable () async throws -> ServerConnection

    /// Clears the screen, the scrollback and the cursor, as the first
    /// attach of `macterm attach` does.
    static let resetScreen = Data("\u{1B}[0m\u{1B}[2J\u{1B}[H".utf8)

    private static let reconnectTries = 5
    private static let reconnectWait: Duration = .milliseconds(200)

    let name: String
    private let host: any PaneSessionHost
    private let connect: Connect
    private let launch: Launch?
    private let wantsForeground: Bool

    private let lock = NSLock()
    private var channel: PaneChannel?
    private var task: Task<Void, Never>?
    private var stopped = false
    /// Input that came before the first channel (a layout's `run:`), sent
    /// after the first attach. Over 1 MiB the rest is dropped.
    private var pendingInput = Data()
    private var attached = false
    private let output = DispatchQueue(label: "PaneSession.input")

    init(name: String, launch: Launch?, wantsForeground: Bool, host: any PaneSessionHost, connect: @escaping Connect) {
        self.name = name
        self.launch = launch
        self.wantsForeground = wantsForeground
        self.host = host
        self.connect = connect
    }

    /// Starts the session and the reading. Call it once.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil, !stopped else { return }
        task = Task { [self] in await run() }
    }

    /// Ends the reading and the channel. The session keeps running.
    func stop() {
        lock.lock()
        stopped = true
        let task = task
        let channel = channel
        self.channel = nil
        lock.unlock()
        task?.cancel()
        if let channel { Task { await channel.close() } }
    }

    // MARK: - Input

    /// Keys, pastes and terminal replies. Dropped while there is no channel,
    /// as a terminal drops keys while its link is down.
    func sendInput(_ data: Data) {
        lock.lock()
        if !attached {
            if pendingInput.count + data.count <= 1 << 20 { pendingInput.append(data) }
            lock.unlock()
            return
        }
        lock.unlock()
        send { try $0.sendInput(data) }
    }

    /// Takes the lead: this client's size becomes the pty's.
    func claim(grid: PaneGrid? = nil) {
        send { channel in
            try channel.send(MactermProtocol.Claim())
        }
        sendSize(grid)
    }

    /// Tells the session the surface's size. Only the leader's size reaches
    /// the pty.
    func sendSize(_ known: PaneGrid? = nil) {
        let grid = known ?? host.paneGrid()
        send { try $0.send(MactermProtocol.Resize(
            cols: grid.cols,
            rows: grid.rows,
            xpixel: Self.clamp(grid.widthPx),
            ypixel: Self.clamp(grid.heightPx)
        )) }
    }

    func pause() async {
        let channel = currentChannel()
        try? await channel?.pause()
    }

    func resume() async {
        let channel = currentChannel()
        try? await channel?.resume()
    }

    private func send(_ body: @escaping @Sendable (PaneChannel) throws -> Void) {
        guard let channel = currentChannel() else { return }
        output.async {
            do { try body(channel) } catch {
                logger.info("pane \(self.name, privacy: .public): send failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func currentChannel() -> PaneChannel? {
        lock.lock()
        defer { lock.unlock() }
        return channel
    }

    private static func clamp(_ value: UInt32) -> UInt16 {
        UInt16(min(value, UInt32(UInt16.max)))
    }

    // MARK: - The reading

    private func run() async {
        var firstAttach = true
        var reconnected = false
        var tries = 0
        while !Task.isCancelled {
            do {
                let connection = try await connect()
                if let launch { try await createSession(on: connection, launch) }
                let channel = try await connection.openChannel(session: name)
                guard install(channel) else {
                    await channel.close()
                    return
                }
                tries = 0
                let grid = host.paneGrid()
                try channel.send(MactermProtocol.Attach(
                    cols: grid.cols, rows: grid.rows,
                    xpixel: Self.clamp(grid.widthPx), ypixel: Self.clamp(grid.heightPx),
                    foreground: wantsForeground
                ))
                if firstAttach {
                    host.paneFeed(Self.resetScreen)
                    firstAttach = false
                }
                let early = markAttached()
                if !early.isEmpty { output.async { try? channel.sendInput(early) } }
                if await read(channel, reconnected: reconnected) { return }
                reconnected = true
                host.paneLinkLost()
            } catch is CancellationError {
                return
            } catch {
                logger.info("pane \(self.name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            uninstall()
            tries += 1
            if tries > Self.reconnectTries {
                host.paneGone()
                return
            }
            try? await Task.sleep(for: Self.reconnectWait)
        }
    }

    /// Reads events until the channel ends. True when the session ended (an
    /// exit) or the reading was cancelled.
    private func read(_ channel: PaneChannel, reconnected: Bool) async -> Bool {
        var needsReset = reconnected
        for await event in channel.events {
            switch event {
            case let .output(data):
                host.paneFeed(data)
            case let .snapshotStart(start):
                // The first snapshot comes over the cleared screen. One after
                // a lost link comes over the old screen: clear it first.
                if needsReset {
                    host.paneFeed(Self.resetScreen)
                    needsReset = false
                }
                _ = start
                host.paneSnapshot(started: true)
            case .snapshotEnd:
                host.paneSnapshot(started: false)
            case let .lead(leader):
                host.paneLeadership(leader)
                // A client that starts to lead sends its size.
                if leader { sendSize() }
            case let .foreground(foreground):
                host.paneForeground(foreground)
            case let .exit(exit):
                host.paneExited(code: exit.code, signal: exit.signal)
                return true
            case .state,
                 .resumed,
                 .title,
                 .other:
                break
            }
        }
        return Task.isCancelled
    }

    /// Makes the session, or finds it. A session whose shell exited while no
    /// app was there is ended and made again, as `zmx attach` did in v1.
    private func createSession(on connection: ServerConnection, _ launch: Launch) async throws {
        let grid = host.paneGrid()
        let args = MactermProtocol.SessionCreate.Args(
            id: name,
            cwd: launch.cwd.map { ProtocolBin(Data($0.utf8)) },
            command: launch.argv.map { $0.map { ProtocolBin(Data($0.utf8)) } },
            cols: grid.cols,
            rows: grid.rows,
            env: launch.env.map { ProtocolBin(Data($0.utf8)) }
        )
        do {
            _ = try await connection.call(MactermProtocol.SessionCreate.self, args)
        } catch let ProtocolControlError.errorResponse(info) where info.code == "exited" {
            _ = try await connection.call(MactermProtocol.SessionKill.self, .init(id: name))
            _ = try await connection.call(MactermProtocol.SessionCreate.self, args)
        }
    }

    private func install(_ channel: PaneChannel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        self.channel = channel
        return true
    }

    private func uninstall() {
        lock.lock()
        channel = nil
        lock.unlock()
    }

    /// The first attach went out: later input goes straight to the channel.
    /// Returns what waited.
    private func markAttached() -> Data {
        lock.lock()
        defer { lock.unlock() }
        attached = true
        defer { pendingInput = Data() }
        return pendingInput
    }
}
