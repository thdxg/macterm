import AppKit
import Foundation
import GhosttyKit
import os

private let logger = Logger(subsystem: appBundleID, category: "SurfaceChannel")

/// A surface that runs from a channel (`PaneSession`) and not from a client
/// on a pty: libghostty's manual surface (fork patch 0022). The session
/// makes the pane's shell from the launch that libghostty resolved
/// (`ghostty_launch_resolve`, fork patch 0023); its bytes are fed to the
/// surface, and the surface's input, size and claims go back on the channel.
extension GhosttyTerminalNSView {
    /// The session and its host, for the callbacks that libghostty makes on
    /// its io thread.
    final class ChannelRuntime: @unchecked Sendable {
        let route: any PaneInputRoute
        let host: SurfaceChannelHost
        /// Ends the reading: the session, or the driver.
        let stop: @Sendable () -> Void

        init(route: any PaneInputRoute, host: SurfaceChannelHost, stop: @escaping @Sendable () -> Void) {
            self.route = route
            self.host = host
            self.stop = stop
        }
    }

    /// The launch that libghostty resolves for `config` (the options of a
    /// normal surface), as strings. nil when it cannot.
    static func resolveLaunch(app: ghostty_app_t, config: inout ghostty_surface_config_s) -> PaneSession.Launch? {
        // The header marks the pointers non-null, so the struct has no zero
        // initializer: libghostty fills zeroed memory.
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<ghostty_launch_s>.size,
            alignment: MemoryLayout<ghostty_launch_s>.alignment
        )
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<ghostty_launch_s>.size)
        let launchPointer = raw.bindMemory(to: ghostty_launch_s.self, capacity: 1)
        defer { raw.deallocate() }
        guard ghostty_launch_resolve(app, &config, launchPointer) else {
            logger.error("ghostty_launch_resolve failed")
            return nil
        }
        defer { ghostty_launch_free(launchPointer) }
        let launch = launchPointer.pointee
        var argv: [String] = []
        for index in 0 ..< launch.argv_count {
            if let arg = launch.argv[index] { argv.append(String(cString: arg)) }
        }
        var env: [String] = []
        for index in 0 ..< launch.env_count {
            env.append("\(String(cString: launch.env[index].key))=\(String(cString: launch.env[index].value))")
        }
        let cwd = launch.cwd.map { String(cString: $0) }
        return PaneSession.Launch(cwd: cwd, argv: argv, env: env)
    }

    /// Sets the manual surface fields. Both callbacks run on libghostty's io
    /// thread, possibly with the renderer lock held: they copy and return.
    static func enableManualIO(_ config: inout ghostty_surface_config_s) {
        config.manual_io = true
        config.manual_write = { userdata, bytes, count in
            guard let userdata else { return }
            let view = Unmanaged<GhosttyTerminalNSView>.fromOpaque(userdata).takeUnretainedValue()
            view.channelRuntime?.route.sendInput(Data(bytes: bytes, count: count))
        }
        config.manual_resize = { userdata, columns, rows, widthPx, heightPx in
            guard let userdata else { return }
            let view = Unmanaged<GhosttyTerminalNSView>.fromOpaque(userdata).takeUnretainedValue()
            guard let runtime = view.channelRuntime else { return }
            let grid = PaneGrid(cols: columns, rows: rows, widthPx: widthPx, heightPx: heightPx)
            runtime.host.setGrid(grid)
            runtime.route.sendSize(grid)
        }
    }

    /// Starts the session of the pane and its reading. The surface exists.
    func startChannel(surface: ghostty_surface_t, launch: PaneSession.Launch, widthPx: UInt32, heightPx: UInt32) {
        let size = ghostty_surface_size(surface)
        let host = SurfaceChannelHost(surface: surface, view: self)
        host.setGrid(PaneGrid(
            cols: size.columns, rows: size.rows,
            widthPx: widthPx > 0 ? widthPx : size.width_px, heightPx: heightPx > 0 ? heightPx : size.height_px
        ))
        let session = PaneSession(
            name: sessionName,
            launch: launch,
            wantsForeground: false,
            host: host,
            connect: { try await LocalSessions.shared.channelConnection() }
        )
        channelRuntime = ChannelRuntime(route: session, host: host, stop: { session.stop() })
        session.start()
    }

    /// Starts the driver of a remote pane. The surface exists.
    func startRemoteChannel(surface: ghostty_surface_t, widthPx: UInt32, heightPx: UInt32) {
        let size = ghostty_surface_size(surface)
        let host = SurfaceChannelHost(surface: surface, view: self)
        host.setGrid(PaneGrid(
            cols: size.columns, rows: size.rows,
            widthPx: widthPx > 0 ? widthPx : size.width_px, heightPx: heightPx > 0 ? heightPx : size.height_px
        ))
        let driver = RemotePaneDriver(name: sessionName, surface: host)
        channelRuntime = ChannelRuntime(
            route: driver,
            host: host,
            stop: { DispatchQueue.main.async { MainActor.assumeIsolated { driver.stop() } } }
        )
        driver.start()
    }

    /// Ends the reading and cuts the host from the surface, before the
    /// surface is freed. The session keeps running.
    func stopChannel() {
        guard let runtime = channelRuntime else { return }
        channelRuntime = nil
        runtime.host.invalidate()
        runtime.stop()
    }
}

/// What a pane's session drives: the surface. Its callbacks come from the
/// session's tasks, so each one hops to the main actor where it touches the
/// pane. `invalidate` runs before the surface is freed: it waits for a feed
/// in flight, and no later one reaches the surface.
final class SurfaceChannelHost: PaneSessionHost, @unchecked Sendable {
    private let lock = NSLock()
    private var surface: ghostty_surface_t?
    private weak var view: GhosttyTerminalNSView?
    private var grid = PaneGrid(cols: 80, rows: 24)

    init(surface: ghostty_surface_t, view: GhosttyTerminalNSView) {
        self.surface = surface
        self.view = view
    }

    func invalidate() {
        lock.lock()
        surface = nil
        lock.unlock()
    }

    func setGrid(_ new: PaneGrid) {
        lock.lock()
        grid = new
        lock.unlock()
    }

    func paneGrid() -> PaneGrid {
        lock.lock()
        defer { lock.unlock() }
        return grid
    }

    func paneFeed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let surface else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ghostty_surface_feed(surface, base, UInt(buffer.count))
        }
    }

    func paneSnapshot(started: Bool) {
        DispatchQueue.main.async { [weak view] in view?.onSnapshotMark?(started) }
    }

    func paneForeground(_ foreground: MactermProtocol.Foreground) {
        guard let report = RemoteForeground(foreground) else { return }
        DispatchQueue.main.async { [weak view] in view?.onRemoteForeground?(report) }
    }

    func paneLeadership(_: Bool) {}

    func paneExited(code _: UInt8?, signal _: UInt8?) {
        DispatchQueue.main.async { [weak view] in view?.onProcessExit?() }
    }

    func paneLinkLost() {}

    func paneGone() {
        DispatchQueue.main.async { [weak view] in view?.onProcessExit?() }
    }
}
