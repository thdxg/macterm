import AppKit
import Foundation
import GhosttyKit
import os

private let logger = Logger(subsystem: appBundleID, category: "GhosttyApp")

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
    @ObservationIgnored
    private var resourcesDir: String?
    @ObservationIgnored
    private var appearanceObserver: NSKeyValueObservation?
    /// Chrome colors as libghostty resolved them for a live surface — the
    /// active `theme = light:X,dark:Y` side already applied. Populated from
    /// `GHOSTTY_ACTION_CONFIG_CHANGE` (see `adoptResolvedColors`) and preferred
    /// over the app-global config getters, which always collapse a split to its
    /// light side. Nil until the first surface reports its config.
    @ObservationIgnored
    private var resolvedColors: ResolvedColors?

    private init() {
        resolveResources()
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            logger.error("ghostty_init failed")
            return
        }
        let (cfgOpt, _) = loadConfig()
        guard let cfg = cfgOpt else {
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

        // React to system light/dark switches. The chrome colors derive from
        // the appearance-resolved `theme = light:X,dark:Y` side (issue #38), so
        // they change with the OS appearance — but they read `NSApp` and theme
        // files, not observable state, so SwiftUI won't recompute on its own.
        // On each change we bump `configVersion` (observed by the root view) and
        // post `.mactermConfigDidChange` so the chrome re-reads MactermTheme.
        // Terminal surfaces handle their own switch via
        // viewDidChangeEffectiveAppearance.
        //
        // Deferred off the init stack: observing `NSApp.effectiveAppearance`
        // (or the first callback it may fire) can re-enter `GhosttyApp.shared`
        // while this `static let` is still initializing, deadlocking its
        // dispatch_once.
        DispatchQueue.main.async { [weak self] in
            self?.appearanceObserver = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
                MainActor.assumeIsolated { GhosttyApp.shared.appearanceDidChange() }
            }
        }
    }

    /// Bump the observable version so SwiftUI re-reads appearance-derived theme
    /// colors, and notify AppKit chrome (window tint) to re-sync.
    private func appearanceDidChange() {
        configVersion += 1
        NotificationCenter.default.post(name: .mactermConfigDidChange, object: nil)
    }

    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    // MARK: - Config

    /// Result of a config (re)load. `missingUserConfigPath` is populated when
    /// the user pointed to a path that doesn't exist on disk — useful to
    /// surface from the Settings reload button. `diagnostics` are libghostty's
    /// parse warnings/errors (unknown keys, bad values, etc.). Both are
    /// empty/nil on a clean reload.
    struct ReloadResult {
        var missingUserConfigPath: String?
        var diagnostics: [String]
    }

    @discardableResult
    func reloadConfig() -> ReloadResult {
        guard let app else { return ReloadResult(diagnostics: []) }
        let (newConfig, result) = loadConfig()
        guard let newConfig else { return result }
        ghostty_app_update_config(app, newConfig)
        // Also update each existing surface so changes take effect immediately
        for view in GhosttyTerminalNSView.allLiveViews() {
            if let surface = view.surface {
                ghostty_surface_update_config(surface, newConfig)
            }
        }
        if let old = config { ghostty_config_free(old) }
        config = newConfig
        configVersion += 1
        NotificationCenter.default.post(name: .mactermConfigDidChange, object: nil)
        return result
    }

    /// Re-apply the *current* config object to the app and every live surface,
    /// without re-reading any file from disk.
    ///
    /// libghostty emits a soft `GHOSTTY_ACTION_RELOAD_CONFIG` whenever a
    /// surface's conditional state changes — most importantly when we call
    /// `ghostty_surface_set_color_scheme`, which flips the `theme =
    /// light:X,dark:Y` split's resolved side. The surface mutates its
    /// conditional state but defers re-deriving its colors until the apprt
    /// hands the config back. If we ignore the action, the surface keeps
    /// rendering the side it resolved at creation (libghostty defaults a new
    /// surface's conditional state to `.light`), so a new dark-mode pane shows
    /// light-side foreground until something else reloads the config. Feeding
    /// the existing config back here re-derives the colors against the updated
    /// conditional state. Each `ghostty_surface_update_config` also makes the
    /// surface re-emit `GHOSTTY_ACTION_CONFIG_CHANGE` with its resolved config,
    /// which is how Macterm's chrome adopts the new split side (see
    /// `adoptResolvedColors`). (Companion to issue #38.)
    func softReloadConfig() {
        guard let app, let config else { return }
        ghostty_app_update_config(app, config)
        for view in GhosttyTerminalNSView.allLiveViews() {
            if let surface = view.surface {
                ghostty_surface_update_config(surface, config)
            }
        }
    }

    /// Reload and surface any user-visible errors (missing file, parse errors)
    /// as a modal alert. Silent on success. Used by both the Settings reload
    /// button and the rebindable "Reload Ghostty config" hotkey.
    func reloadAndReport() {
        let result = reloadConfig()
        var lines: [String] = []
        if let missing = result.missingUserConfigPath {
            lines.append("File not found: \(missing)")
        }
        if !result.diagnostics.isEmpty {
            lines.append(contentsOf: result.diagnostics)
        }
        guard !lines.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText =
            result.missingUserConfigPath != nil
                ? "Ghostty config not found"
                : "Issues in your Ghostty config"
        alert.informativeText = lines.joined(separator: "\n\n")
        alert.alertStyle = result.missingUserConfigPath != nil ? .warning : .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Color accessors prefer the colors libghostty resolved for a live surface
    /// (`resolvedColors`, fed by `GHOSTTY_ACTION_CONFIG_CHANGE`): that config has
    /// the active `theme = light:X,dark:Y` side applied, so it's correct for both
    /// plain and split themes — the same source Ghostty's own window chrome uses.
    /// Before the first surface reports (e.g. the launch window) they fall back
    /// to parsing the appearance-resolved theme file (issue #38), then to
    /// libghostty's app-global getters, which are correct only for a plain theme.
    var backgroundColor: NSColor {
        if let rgb = resolvedColors?.background { return nsColor(rgb) }
        if let hex = resolvedThemeColors()?.background, let c = nsColor(fromHex: hex) { return c }
        return configColor("background") ?? NSColor(srgbRed: 0.11, green: 0.11, blue: 0.14, alpha: 1)
    }

    var foregroundColor: NSColor {
        if let rgb = resolvedColors?.foreground { return nsColor(rgb) }
        if let hex = resolvedThemeColors()?.foreground, let c = nsColor(fromHex: hex) { return c }
        return configColor("foreground") ?? .white
    }

    var accentColor: NSColor { paletteColor(at: 4) ?? foregroundColor }

    func paletteColor(at index: Int) -> NSColor? {
        guard (0 ..< 256).contains(index) else { return nil }
        if let rgb = resolvedColors?.palette[index] { return nsColor(rgb) }
        if let hex = resolvedThemeColors()?.palette[index], let c = nsColor(fromHex: hex) { return c }
        guard let config else { return nil }
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

    /// An explicit shell command from the user's ghostty config (`command =`),
    /// used as the fallback when a layout pane doesn't name its own `shell`.
    /// Returns nil when the config doesn't set one — and that nil is important:
    /// the caller then leaves `config.command` unset so libghostty resolves the
    /// user's *login* shell itself (via the password database). We deliberately
    /// do NOT fall back to `$SHELL`: that's the shell of whatever process
    /// launched the app (often `/bin/zsh` from the launchd/login chain), not the
    /// user's login shell, so using it forced every pane onto `zsh` regardless
    /// of the user's real shell.
    var configuredShell: String? {
        guard let command = configString("command"), !command.isEmpty else { return nil }
        return command
    }

    private func configString(_ key: String) -> String? {
        guard let config else { return nil }
        var str = ghostty_string_s()
        guard ghostty_config_get(config, &str, key, UInt(key.utf8.count)), let ptr = str.ptr else { return nil }
        return String(bytes: UnsafeRawBufferPointer(start: ptr, count: Int(str.len)), encoding: .utf8)
    }

    private func loadConfig() -> (ghostty_config_t?, ReloadResult) {
        var result = ReloadResult(diagnostics: [])
        guard let cfg = ghostty_config_new() else { return (nil, result) }

        // Recompute the wrapper files against the user's config as it exists
        // right now: the overrides' shell-integration-features line merges the
        // user's own value (#75), which may have changed since the last load.
        MactermConfig.shared.regenerate()

        // Three-layer ghostty config:
        //   1. Macterm defaults — tasteful first-launch values.
        //   2. User's Ghostty config — overrides any default. Source of truth
        //      for all ghostty-shaped settings (theme, font, palette, keybinds,
        //      shell integration, etc.).
        //   3. Macterm overrides — keys Macterm absolutely needs to control,
        //      currently just background-opacity/blur for the window-level
        //      translucency contract. Loaded last so it overrides the user.
        // libghostty merges last-wins, so this ordering produces:
        //   Macterm defaults < user's Ghostty config < Macterm overrides
        MactermConfig.shared.defaultsPath.withCString { ghostty_config_load_file(cfg, $0) }
        let userPath = Preferences.shared.expandedUserGhosttyConfigPath
        if !userPath.isEmpty {
            if FileManager.default.fileExists(atPath: userPath) {
                userPath.withCString { ghostty_config_load_file(cfg, $0) }
            } else {
                logger.info("user Ghostty config not found at \(userPath, privacy: .public); skipping")
                result.missingUserConfigPath = userPath
            }
        }
        MactermConfig.shared.overridesPath.withCString { ghostty_config_load_file(cfg, $0) }
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)

        // Collect ghostty's diagnostics (parse errors, unknown keys, bad
        // values). Log them and surface to the caller so the Settings reload
        // button can show them in an alert.
        let diagCount = ghostty_config_diagnostics_count(cfg)
        for i in 0 ..< diagCount {
            let diag = ghostty_config_get_diagnostic(cfg, i)
            if let msg = diag.message {
                let s = String(cString: msg)
                logger.warning("config: \(s, privacy: .public)")
                result.diagnostics.append(s)
            }
        }

        return (cfg, result)
    }

    /// Candidate ghostty resource dirs, highest priority first. Macterm ships
    /// the ghostty resources in its own bundle (downloaded by setup.sh) under
    /// `Contents/Resources/ghostty`, mirroring a real Ghostty.app, with the
    /// compiled terminfo DB at the sibling `Contents/Resources/terminfo`. So
    /// TERM=xterm-ghostty, named themes, and shell integration resolve with no
    /// Ghostty.app install. The installed Ghostty.app dirs remain as fallbacks
    /// for the rare case the bundle is missing them (e.g. an unprepared dev
    /// checkout).
    private static let resourcePaths: [String] = {
        var paths: [String] = []
        if let resources = Bundle.main.resourceURL?.path {
            paths.append(resources + "/ghostty")
        }
        paths.append("/Applications/Ghostty.app/Contents/Resources/ghostty")
        paths.append(NSHomeDirectory() + "/Applications/Ghostty.app/Contents/Resources/ghostty")
        return paths
    }()

    private func resolveResources() {
        // Always resolve from our own candidates (bundle first), ignoring any
        // inherited GHOSTTY_RESOURCES_DIR. A stale value — e.g. pointing at an
        // installed Ghostty.app/Macterm.app that lacks terminfo — would
        // otherwise shadow our complete bundle and leave libghostty deriving a
        // broken TERMINFO, reintroducing #39/#40.
        //
        // We only set GHOSTTY_RESOURCES_DIR. TERMINFO is NOT set here on
        // purpose: libghostty unconditionally overwrites it at shell spawn with
        // dirname(GHOSTTY_RESOURCES_DIR)/terminfo (src/termio/Exec.zig), so any
        // setenv here would be clobbered. Because our resources dir is
        // .../Resources/ghostty, that derivation lands on .../Resources/terminfo
        // — the sibling dir we ship — which is exactly what we want.
        let resolver = GhosttyResourceResolver(
            candidates: Self.resourcePaths,
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
        guard let resourcesDir = resolver.resolve() else {
            unsetenv("GHOSTTY_RESOURCES_DIR")
            return
        }
        self.resourcesDir = resourcesDir
        setenv("GHOSTTY_RESOURCES_DIR", resourcesDir, 1)
    }

    // MARK: - Theme split resolution (issue #38)

    /// When the effective `theme` is a `light:X,dark:Y` split, the colors of the
    /// side matching the current OS appearance — read straight from the theme
    /// file, since libghostty's config getters always resolve a split to the
    /// light side. Nil for a plain theme (the getters handle those correctly).
    private func resolvedThemeColors() -> ThemeResolver.Colors? {
        guard let resourcesDir else { return nil }
        // Reconstruct the effective `theme` from the layers we control, matching
        // libghostty's last-wins merge: our defaults, then the user's config.
        var configText = (try? String(contentsOfFile: MactermConfig.shared.defaultsPath, encoding: .utf8)) ?? ""
        let userPath = Preferences.shared.expandedUserGhosttyConfigPath
        if !userPath.isEmpty, let userText = try? String(contentsOfFile: userPath, encoding: .utf8) {
            configText += "\n" + userText
        }
        guard let themeValue = ThemeResolver.themeValue(inConfigText: configText),
              let side = ThemeResolver.resolve(themeValue: themeValue, scheme: currentScheme)
        else { return nil }

        // A theme value is either a bare name (resolved against the bundled
        // themes dir) or an absolute / `~` path to a user theme file — pass the
        // latter through untouched instead of nesting it under the themes dir.
        let themeFile: String =
            side.hasPrefix("/") || side.hasPrefix("~")
                ? (side as NSString).expandingTildeInPath
                : resourcesDir + "/themes/" + side
        guard let themeText = try? String(contentsOfFile: themeFile, encoding: .utf8) else { return nil }
        return ThemeResolver.colors(inThemeFile: themeText)
    }

    private var currentScheme: ThemeResolver.Scheme {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    // MARK: - Surface-resolved chrome colors (Ghostty's CONFIG_CHANGE pattern)

    /// A snapshot of the chrome colors read out of a libghostty config handle,
    /// held as plain values so it can cross from the action callback (which may
    /// run off the main actor) to the main actor. `palette` always has 256
    /// entries; an entry is nil only when the getter fails.
    struct ResolvedColors: Equatable {
        struct RGB: Equatable {
            var r: UInt8
            var g: UInt8
            var b: UInt8
        }

        var background: RGB?
        var foreground: RGB?
        var palette: [RGB?]
    }

    /// Read the chrome colors out of a libghostty config handle. `nonisolated`
    /// so the `GHOSTTY_ACTION_CONFIG_CHANGE` callback can snapshot synchronously
    /// while the handle is valid — libghostty owns it only for the duration of
    /// that call, so the values must be copied out before returning.
    nonisolated static func readColors(from cfg: ghostty_config_t) -> ResolvedColors {
        func color(_ key: String) -> ResolvedColors.RGB? {
            var c = ghostty_config_color_s()
            guard ghostty_config_get(cfg, &c, key, UInt(key.utf8.count)) else { return nil }
            return .init(r: c.r, g: c.g, b: c.b)
        }

        var palette = [ResolvedColors.RGB?](repeating: nil, count: 256)
        var raw = ghostty_config_palette_s()
        let key = "palette"
        if ghostty_config_get(cfg, &raw, key, UInt(key.utf8.count)) {
            withUnsafePointer(to: &raw.colors) {
                $0.withMemoryRebound(to: ghostty_config_color_s.self, capacity: 256) { ptr in
                    for i in 0 ..< 256 {
                        palette[i] = .init(r: ptr[i].r, g: ptr[i].g, b: ptr[i].b)
                    }
                }
            }
        }
        return ResolvedColors(background: color("background"), foreground: color("foreground"), palette: palette)
    }

    /// Adopt the colors libghostty resolved for a live surface (delivered via
    /// `GHOSTTY_ACTION_CONFIG_CHANGE`). Bumps `configVersion` and notifies the
    /// AppKit chrome so it re-reads `MactermTheme`, but only when the colors
    /// actually changed — config-change actions fire for many reasons.
    func adoptResolvedColors(_ colors: ResolvedColors) {
        guard resolvedColors != colors else { return }
        resolvedColors = colors
        configVersion += 1
        NotificationCenter.default.post(name: .mactermConfigDidChange, object: nil)
    }

    private func nsColor(_ rgb: ResolvedColors.RGB) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }

    private func nsColor(fromHex hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255,
            alpha: 1
        )
    }
}
