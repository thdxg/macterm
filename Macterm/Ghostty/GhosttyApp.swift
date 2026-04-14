import AppKit
import Foundation
import GhosttyKit
import os

private let logger = Logger(subsystem: "app.macterm", category: "GhosttyApp")

/// Manages the libghostty application lifecycle: init, config, tick loop, color queries.
@MainActor @Observable
final class GhosttyApp {
    static let shared = GhosttyApp()

    @ObservationIgnored
    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?
    private(set) var configVersion = 0
    @ObservationIgnored
    private var tickTimer: Timer?
    @ObservationIgnored
    private let callbacks = GhosttyCallbacks()

    private init() {
        resolveResources()
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            logger.error("ghostty_init failed")
            return
        }
        guard let cfg = loadConfig() else {
            logger.error("ghostty_config_new failed")
            return
        }

        var rt = ghostty_runtime_config_s()
        rt.userdata = Unmanaged.passUnretained(self).toOpaque()
        rt.supports_selection_clipboard = true
        rt.wakeup_cb = { _ in GhosttyApp.shared.callbacks.wakeup() }
        rt.action_cb = { _, target, action in GhosttyApp.shared.callbacks.action(target: target, action: action) }
        rt.read_clipboard_cb = { ud, loc, state in GhosttyApp.shared.callbacks.readClipboard(ud: ud, location: loc, state: state) }
        rt.confirm_read_clipboard_cb = { ud, content, state, _ in
            GhosttyApp.shared.callbacks.confirmReadClipboard(ud: ud, content: content, state: state)
        }
        rt.write_clipboard_cb = { _, _, content, len, _ in GhosttyApp.shared.callbacks.writeClipboard(content: content, len: UInt(len)) }
        rt.close_surface_cb = { ud, _ in GhosttyApp.shared.callbacks.closeSurface(ud: ud) }

        guard let createdApp = ghostty_app_new(&rt, cfg) else {
            logger.error("ghostty_app_new failed")
            ghostty_config_free(cfg)
            return
        }
        app = createdApp
        config = cfg

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Config

    func reloadConfig() {
        guard let app, let newConfig = loadConfig() else { return }
        ghostty_app_update_config(app, newConfig)
        // Also update each existing surface so changes take effect immediately
        for view in TerminalViewCache.shared.allViews() {
            if let surface = view.surface {
                ghostty_surface_update_config(surface, newConfig)
            }
        }
        if let old = config { ghostty_config_free(old) }
        config = newConfig
        configVersion += 1
        NotificationCenter.default.post(name: .mactermConfigDidChange, object: nil)
    }

    var backgroundOpacity: Double {
        guard let config else { return 1.0 }
        var value = 1.0
        let key = "background-opacity"
        return ghostty_config_get(config, &value, key, UInt(key.utf8.count)) ? max(0, min(1, value)) : 1.0
    }

    var backgroundColor: NSColor { configColor("background") ?? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.14, alpha: 1) }
    var foregroundColor: NSColor { configColor("foreground") ?? .white }
    var accentColor: NSColor { paletteColor(at: 4) ?? foregroundColor }

    func paletteColor(at index: Int) -> NSColor? {
        guard let config, (0 ..< 256).contains(index) else { return nil }
        var palette = ghostty_config_palette_s()
        let key = "palette"
        guard ghostty_config_get(config, &palette, key, UInt(key.utf8.count)) else { return nil }
        let c = withUnsafePointer(to: &palette.colors) {
            $0.withMemoryRebound(to: ghostty_config_color_s.self, capacity: 256) { $0[index] }
        }
        return NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
    }

    private func configColor(_ key: String) -> NSColor? {
        guard let config else { return nil }
        var color = ghostty_config_color_s()
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else { return nil }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
    }

    private func loadConfig() -> ghostty_config_t? {
        guard let cfg = ghostty_config_new() else { return nil }
        MactermConfig.shared.ghosttyConfigPath.withCString { ghostty_config_load_file(cfg, $0) }
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)

        // Log config diagnostics as warnings
        let diagCount = ghostty_config_diagnostics_count(cfg)
        for i in 0 ..< diagCount {
            let diag = ghostty_config_get_diagnostic(cfg, i)
            if let msg = diag.message {
                logger.warning("config: \(String(cString: msg))")
            }
        }

        return cfg
    }

    private static let resourcePaths = [
        "/Applications/Ghostty.app/Contents/Resources/ghostty",
        NSHomeDirectory() + "/Applications/Ghostty.app/Contents/Resources/ghostty",
    ]

    private func resolveResources() {
        if let existing = getenv("GHOSTTY_RESOURCES_DIR").map({ String(cString: $0) }) {
            guard Self.resourcePaths.contains(where: { existing.hasPrefix($0) }) else {
                unsetenv("GHOSTTY_RESOURCES_DIR")
                return
            }
            return
        }
        for path in Self.resourcePaths where FileManager.default.fileExists(atPath: path + "/shell-integration") {
            setenv("GHOSTTY_RESOURCES_DIR", path, 1)
            return
        }
    }
}
