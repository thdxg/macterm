import AppKit
import GhosttyKit

/// Routes libghostty runtime callbacks to the appropriate terminal views.
final class GhosttyCallbacks: @unchecked Sendable {
    func wakeup() {
        DispatchQueue.main.async { GhosttyApp.shared.tick() }
    }

    func action(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            // OSC 0/2. Whether the string becomes the tab name is decided by
            // the pane (it's honored only while a real program — not the shell
            // — is in the foreground, see `Pane.receiveReportedTitle`); its
            // arrival is also a command-boundary signal that refreshes the
            // foreground-process name.
            guard let view = surfaceView(from: target) else { return true }
            let title = action.action.set_title.title.flatMap { String(cString: $0) } ?? ""
            DispatchQueue.main.async { view.surfaceDidReportTitle(title) }
            return true
        case GHOSTTY_ACTION_START_SEARCH:
            guard let view = surfaceView(from: target) else { return true }
            let needle = action.action.start_search.needle.flatMap { String(cString: $0) }
            DispatchQueue.main.async { view.onSearchStart?(needle) }
            return true
        case GHOSTTY_ACTION_END_SEARCH:
            guard let view = surfaceView(from: target) else { return true }
            DispatchQueue.main.async { view.onSearchEnd?() }
            return true
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let view = surfaceView(from: target) else { return true }
            let v = action.action.search_total.total
            let value = v >= 0 ? Int(v) : nil
            DispatchQueue.main.async { view.onSearchTotal?(value) }
            return true
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let view = surfaceView(from: target) else { return true }
            let v = action.action.search_selected.selected
            let value = v >= 0 ? Int(v) : nil
            DispatchQueue.main.async { view.onSearchSelected?(value) }
            return true
        case GHOSTTY_ACTION_PWD:
            guard let view = surfaceView(from: target), let ptr = action.action.pwd.pwd else { return true }
            let pwd = String(cString: ptr)
            DispatchQueue.main.async { view.currentPwd = pwd }
            return true
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            guard let view = surfaceView(from: target) else { return true }
            let title = action.action.desktop_notification.title.flatMap { String(cString: $0) } ?? ""
            let body = action.action.desktop_notification.body.flatMap { String(cString: $0) } ?? ""
            DispatchQueue.main.async { view.onDesktopNotification?(title, body) }
            return true
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            guard let view = surfaceView(from: target) else { return true }
            let exitCode = action.action.command_finished.exit_code
            let duration = action.action.command_finished.duration
            DispatchQueue.main.async { view.onCommandFinished?(exitCode, duration) }
            return true
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            guard let view = surfaceView(from: target) else { return true }
            let state = action.action.progress_report.state
            let running = state == GHOSTTY_PROGRESS_STATE_SET || state == GHOSTTY_PROGRESS_STATE_INDETERMINATE
            DispatchQueue.main.async { view.surfaceDidReportProgress(running: running) }
            return true
        case GHOSTTY_ACTION_SCROLLBAR:
            guard let view = surfaceView(from: target) else { return true }
            let s = action.action.scrollbar
            DispatchQueue.main.async { view.surfaceDidUpdateScrollbar(total: s.total, offset: s.offset, len: s.len) }
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            // libghostty fires this (with soft = true) when a surface's
            // conditional state changes — notably on set_color_scheme, which
            // re-resolves a `theme = light:X,dark:Y` split. The surface won't
            // re-derive its colors until we hand the config back, so a soft
            // reload re-applies the current config. A hard reload re-reads the
            // user's config from disk. Without this, new dark-mode panes render
            // the light-side foreground until a manual reload. See
            // GhosttyApp.softReloadConfig.
            let soft = action.action.reload_config.soft
            DispatchQueue.main.async {
                if soft {
                    GhosttyApp.shared.softReloadConfig()
                } else {
                    GhosttyApp.shared.reloadConfig()
                }
            }
            return true
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            // libghostty hands us a surface's *resolved* config — the active
            // `theme = light:X,dark:Y` side already applied. Reading the chrome
            // colors from it (rather than the app-global config, whose getters
            // always collapse a split to its light side) lets the window and
            // sidebar follow the real appearance, matching how Ghostty's own
            // chrome works. The config handle is owned by libghostty and valid
            // only for this call, so snapshot synchronously before handing the
            // plain values to the main actor. App-target changes carry no
            // surface conditional state, so only surface targets are useful.
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let cfg = action.action.config_change.config
            else { return false }
            let snapshot = GhosttyApp.readColors(from: cfg)
            DispatchQueue.main.async { GhosttyApp.shared.adoptResolvedColors(snapshot) }
            return true
        default:
            return false
        }
    }

    func readClipboard(ud: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?) -> Bool {
        let text = Self.readPasteboardText() ?? ""
        text.withCString { ghostty_surface_complete_clipboard_request(surface(from: ud), $0, state, false) }
        return true
    }

    // MARK: - Pasteboard text resolution (shared with GhosttyTerminalNSView)

    /// Characters to escape when pasting paths into the shell.
    private static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    /// Escape shell-sensitive characters in a string by prefixing each with a
    /// backslash. Suitable for inserting paths/URLs into a live terminal buffer.
    static func shellEscape(_ s: String) -> String {
        var result = s
        for char in escapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }

    /// Returns pasted text from the pasteboard: file paths (Finder drag/copy)
    /// fall back to plain string. Called by both the context-menu paste path
    /// and the libghostty Cmd+V clipboard path.
    ///
    /// When the pasteboard holds a raw image (e.g. a screenshot) and no text,
    /// the image is written to a temporary PNG file and its path is returned —
    /// matching base Ghostty's behavior. This is what lets TUIs such as Claude
    /// Code receive pasted images: they read the file at the pasted path.
    static func readPasteboardText(from pb: NSPasteboard = .general) -> String? {
        // Finder copies files as NSURL data, not strings.
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let paths = urls
                .map { url in
                    url.isFileURL ? Self.shellEscape(url.path(percentEncoded: false)) : url.absoluteString
                }
                .filter { !$0.isEmpty }
            if !paths.isEmpty {
                return paths.joined(separator: " ")
            }
        }

        // Prefer real text when present.
        if let s = pb.string(forType: .string), !s.isEmpty {
            return s
        }

        // Raw image on the clipboard (screenshot, "Copy Image", etc.): persist
        // it to a temp PNG and paste the escaped path.
        if let path = Self.imagePasteboardPath(pb) {
            return Self.shellEscape(path)
        }

        return nil
    }

    /// Cheap, side-effect-free check for whether there is anything pasteable
    /// (text, file URLs, or an image). Used to enable/disable the Paste menu
    /// item without writing a temp file.
    static func hasPasteboardContent(in pb: NSPasteboard = .general) -> Bool {
        let types: [NSPasteboard.PasteboardType] = [.string, .fileURL, .URL, .png, .tiff]
        return pb.availableType(from: types) != nil
    }

    /// If the pasteboard contains image data, write a normalized PNG to the
    /// temporary directory and return its absolute path. Returns nil when no
    /// image is available or the write fails.
    static func imagePasteboardPath(_ pb: NSPasteboard) -> String? {
        // Pull raw bytes for the best available image type, normalizing to PNG.
        let pngData: Data? = if let data = pb.data(forType: .png) {
            data
        } else if let data = pb.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: data)
        {
            rep.representation(using: .png, properties: [:])
        } else if let image = NSImage(pasteboard: pb),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff)
        {
            rep.representation(using: .png, properties: [:])
        } else {
            nil
        }

        guard let data = pngData else { return nil }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-paste", isDirectory: true)
        let url = dir.appendingPathComponent("image-\(UUID().uuidString).png")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }

    func confirmReadClipboard(ud: UnsafeMutableRawPointer?, content: UnsafePointer<CChar>?, state: UnsafeMutableRawPointer?) {
        guard let content else { return }
        ghostty_surface_complete_clipboard_request(surface(from: ud), content, state, true)
    }

    func writeClipboard(content: UnsafePointer<ghostty_clipboard_content_s>?, len: UInt) {
        guard let content, len > 0 else { return }
        for item in UnsafeBufferPointer(start: content, count: Int(len)) {
            guard let data = item.data, let mime = item.mime, String(cString: mime).hasPrefix("text/plain") else { continue }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(cString: data), forType: .string)
            return
        }
    }

    func closeSurface(ud: UnsafeMutableRawPointer?) {
        guard let ud else { return }
        let view = Unmanaged<GhosttyTerminalNSView>.fromOpaque(ud).takeUnretainedValue()
        DispatchQueue.main.async { view.onProcessExit?() }
    }

    private func surfaceView(from target: ghostty_target_s) -> GhosttyTerminalNSView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let ud = ghostty_surface_userdata(surface)
        else { return nil }
        return Unmanaged<GhosttyTerminalNSView>.fromOpaque(ud).takeUnretainedValue()
    }

    private func surface(from ud: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        guard let ud else { return nil }
        return Unmanaged<GhosttyTerminalNSView>.fromOpaque(ud).takeUnretainedValue().surface
    }
}
