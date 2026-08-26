import AppKit
import GhosttyKit
import os
import UniformTypeIdentifiers

private let logger = Logger(subsystem: appBundleID, category: "GhosttyCallbacks")

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
        case GHOSTTY_ACTION_RENDER:
            guard let view = surfaceView(from: target) else { return false }
            DispatchQueue.main.async { view.surfaceDidRender() }
            // Do not consume the action: keep libghostty's existing render path
            // unchanged, and use this only as an activity signal.
            return false
        case GHOSTTY_ACTION_COLOR_CHANGE:
            guard action.action.color_change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND,
                  let view = surfaceView(from: target)
            else { return false }
            let change = action.action.color_change
            let color = NSColor(
                srgbRed: CGFloat(change.r) / 255,
                green: CGFloat(change.g) / 255,
                blue: CGFloat(change.b) / 255,
                alpha: 1
            )
            DispatchQueue.main.async { view.surfaceDidChangeBackgroundColor(color) }
            return true
        case GHOSTTY_ACTION_OUTPUT_ACTIVITY:
            // Throttled heartbeat from the pty IO path — fires while the
            // program produces output, even when the surface is occluded and
            // the renderer (and thus the scrollbar action) is parked. Carries
            // the same geometry as GHOSTTY_ACTION_SCROLLBAR so the tracker can
            // tell real output growth from in-place redraws.
            guard let view = surfaceView(from: target) else { return true }
            let s = action.action.output_activity
            DispatchQueue.main.async { view.surfaceDidOutputActivity(total: s.total, offset: s.offset, len: s.len) }
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
                  let view = surfaceView(from: target),
                  let cfg = action.action.config_change.config
            else { return false }
            let snapshot = GhosttyApp.readColors(from: cfg)
            let background = snapshot.background.map {
                NSColor(
                    srgbRed: CGFloat($0.r) / 255,
                    green: CGFloat($0.g) / 255,
                    blue: CGFloat($0.b) / 255,
                    alpha: 1
                )
            }
            DispatchQueue.main.async {
                view.surfaceConfigDidChange(backgroundColor: background)
                GhosttyApp.shared.adoptResolvedColors(snapshot)
            }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            // Keybind actions that end in opening something — link clicks,
            // `write_scrollback_file:open` and friends. Left unhandled,
            // libghostty still opens the file itself (a spawned `open -t`),
            // but logs it as an apprt failure; handling it here matches
            // Ghostty.app. The url bytes are NOT null-terminated (`len`
            // bounds them) and the pointer is owned by libghostty for this
            // call only, so copy synchronously.
            let payload = action.action.open_url
            guard let ptr = payload.url, payload.len > 0 else { return true }
            let urlString = String(
                decoding: UnsafeRawBufferPointer(start: ptr, count: Int(payload.len)),
                as: UTF8.self
            )
            let kind = payload.kind
            DispatchQueue.main.async { Self.openURL(urlString, kind: kind) }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            // The pointer shape for the current mouse position — I-beam over
            // text, pointing hand over an OSC 8 link, resize arrows for TUI
            // drags. Applied as the scroll view's documentCursor.
            guard let view = surfaceView(from: target) else { return true }
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { view.surfaceDidChangeMouseShape(shape) }
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            // mouse-hide-while-typing. Hidden-until-move matches Ghostty.app:
            // any physical mouse movement reveals the cursor again, so we
            // never need to balance hide/unhide pairs.
            guard surfaceView(from: target) != nil else { return true }
            let hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
            DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(hidden) }
            return true
        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            // The URL under the pointer, for the pane's hover banner. Zero
            // length means the pointer left the link. Bytes are len-bounded
            // (not null-terminated) and owned by libghostty for this call.
            guard let view = surfaceView(from: target) else { return true }
            let link = action.action.mouse_over_link
            var url: String?
            if let ptr = link.url, link.len > 0 {
                url = String(
                    decoding: UnsafeRawBufferPointer(start: ptr, count: Int(link.len)),
                    as: UTF8.self
                )
            }
            DispatchQueue.main.async { view.surfaceDidHoverLink(url) }
            return true
        case GHOSTTY_ACTION_SECURE_INPUT:
            // App target: the user's `toggle_secure_input` keybind. Surface
            // target: libghostty detected a password prompt — honored only
            // when `macos-auto-secure-input` allows (checked on the main
            // queue: config access is main-actor).
            let mode = action.action.secure_input
            switch target.tag {
            case GHOSTTY_TARGET_APP:
                DispatchQueue.main.async {
                    switch mode {
                    case GHOSTTY_SECURE_INPUT_ON: SecureInput.shared.setGlobal(true)
                    case GHOSTTY_SECURE_INPUT_OFF: SecureInput.shared.setGlobal(false)
                    default: SecureInput.shared.toggleGlobal()
                    }
                }
                return true
            case GHOSTTY_TARGET_SURFACE:
                guard let view = surfaceView(from: target) else { return true }
                DispatchQueue.main.async {
                    guard GhosttyApp.shared.autoSecureInput else { return }
                    switch mode {
                    case GHOSTTY_SECURE_INPUT_ON: view.passwordInput = true
                    case GHOSTTY_SECURE_INPUT_OFF: view.passwordInput = false
                    default: view.passwordInput.toggle()
                    }
                }
                return true
            default:
                return false
            }
        case GHOSTTY_ACTION_RING_BELL:
            // BEL. The `title`/`border` bell-features are per-tab UI Macterm
            // doesn't implement; the app-level features (beep, custom sound,
            // dock attention) are handled here for any surface.
            guard target.tag == GHOSTTY_TARGET_SURFACE else { return false }
            DispatchQueue.main.async { Self.ringBell() }
            return true
        case GHOSTTY_ACTION_OPEN_CONFIG:
            // The `open_config` keybind. Macterm's source of truth is the
            // user's own ghostty config file, so open that — created empty
            // first if it doesn't exist yet, matching Ghostty.app.
            DispatchQueue.main.async { Self.openUserConfig() }
            return true
        case GHOSTTY_ACTION_CHECK_FOR_UPDATES:
            // Same guard as the Check for Update command: no-op while a
            // Sparkle check is already in flight.
            DispatchQueue.main.async {
                guard Updater.shared.canCheckForUpdates else { return }
                Updater.shared.checkForUpdates()
            }
            return true
        case GHOSTTY_ACTION_COPY_TITLE_TO_CLIPBOARD:
            // The pane owns title state (program title / process name), so it
            // supplies the string via `titleProvider`.
            guard let view = surfaceView(from: target) else { return true }
            DispatchQueue.main.async {
                guard let title = view.titleProvider?(), !title.isEmpty else { return }
                Self.setPasteboardString(title)
            }
            return true
        case GHOSTTY_ACTION_PROMPT_TITLE:
            // `prompt_surface_title`. Macterm titles live on tabs (a surface
            // has no separate title UI), so both the surface and tab variants
            // route to the containing tab's rename flow.
            guard let view = surfaceView(from: target) else { return true }
            DispatchQueue.main.async { view.onPromptTitle?() }
            return true
        case GHOSTTY_ACTION_SET_TAB_TITLE:
            // The `set_tab_title` keybind: an explicit user-driven title, so
            // it maps to the tab's customTitle (what rename-tab sets). Empty
            // restores the automatic title, same contract as Ghostty.app.
            guard let view = surfaceView(from: target) else { return true }
            let title = action.action.set_tab_title.title.flatMap { String(cString: $0) } ?? ""
            DispatchQueue.main.async { view.onSetTabTitle?(title.isEmpty ? nil : title) }
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // Log-only, and deliberately `return false` so the core still
            // renders its own message / abnormal-exit overlay — the error UI
            // Macterm relies on. The report is NOT used to classify the exit:
            // measured on macOS, `exit_code` is always 0 (even for an ssh
            // resolution failure that exits 255 — ghostty's Surface.zig notes
            // Darwin exit-code detection doesn't work), so the remote
            // drop-vs-deliberate-end decision asks the host instead
            // (`AppState.handleProcessExit`). The log line remains the only
            // record of what the child reported.
            let info = action.action.child_exited
            let runtime = info.timetime_ms // upstream's field name (sic) for runtime
            logger.info("child exited: code=\(info.exit_code, privacy: .public) runtime=\(runtime, privacy: .public)ms")
            return false
        case GHOSTTY_ACTION_RENDERER_HEALTH:
            // No recovery UI (Ghostty.app shows a banner); surfacing the
            // transition in the log is what makes a black pane diagnosable.
            let health = action.action.renderer_health
            if health == GHOSTTY_RENDERER_HEALTH_UNHEALTHY {
                logger.error("renderer reported unhealthy for a surface")
            } else {
                logger.info("renderer recovered for a surface")
            }
            return true
        default:
            // Deliberately unhandled: window/tab/split management actions
            // (NEW_TAB, NEW_SPLIT, GOTO_*, TOGGLE_FULLSCREEN, QUIT, …) —
            // those concepts are Macterm-owned via AppCommand/hotkeys, not
            // ghostty keybinds; GTK/iOS-only actions (SHOW_GTK_INSPECTOR,
            // SHOW_ON_SCREEN_KEYBOARD); the imgui INSPECTOR; sizing hints
            // (CELL_SIZE, SIZE_LIMIT, INITIAL_SIZE, RESET_WINDOW_SIZE) that
            // don't map onto a single shared window of splits; UNDO/REDO
            // (no app-level undo stack); COLOR_CHANGE (OSC 4/10/11 recolors
            // the grid core-side; Macterm's chrome follows the resolved
            // theme via CONFIG_CHANGE, not per-surface dynamic colors);
            // SELECTION_CHANGED (accessibility text APIs not implemented);
            // and KEY_SEQUENCE/KEY_TABLE progress UI (sequences themselves
            // still work core-side). SHOW_CHILD_EXITED stays unhandled on
            // purpose: returning false makes the core render its own
            // abnormal-exit overlay, which is the error UI Macterm relies on.
            return false
        }
    }

    /// Ring the terminal bell per the user's `bell-features`: the system
    /// beep, an optional custom sound, and a dock-bounce attention request
    /// (which macOS shows only while the app is inactive).
    @MainActor
    private static func ringBell() {
        let features = GhosttyApp.shared.bellFeatures
        if features.contains(.system) {
            NSSound.beep()
        }
        if features.contains(.audio),
           let path = GhosttyApp.shared.bellAudioPath,
           let sound = NSSound(contentsOfFile: path, byReference: false)
        {
            sound.volume = GhosttyApp.shared.bellAudioVolume
            sound.play()
        }
        if features.contains(.attention) {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    /// Open the highest-precedence user config. With no additional file, ask
    /// libghostty for its preferred default edit path.
    @MainActor
    private static func openUserConfig() {
        let path: String
        let selection = Preferences.shared.ghosttyConfigSelection
        if let customPath = selection.customPaths.last {
            path = (customPath as NSString).expandingTildeInPath
        } else if selection.loadsDefaultFiles {
            let value = ghostty_config_open_path()
            defer { ghostty_string_free(value) }
            guard let pointer = value.ptr, value.len > 0 else { return }
            let bytes = UnsafeBufferPointer(start: pointer, count: Int(value.len)).map { UInt8(bitPattern: $0) }
            guard let resolved = String(bytes: bytes, encoding: .utf8), !resolved.isEmpty else { return }
            path = resolved
        } else {
            return
        }

        if !FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        openURL(path, kind: GHOSTTY_ACTION_OPEN_URL_KIND_TEXT)
    }

    // MARK: - Open URL (GHOSTTY_ACTION_OPEN_URL)

    /// The URL a `GHOSTTY_ACTION_OPEN_URL` payload string denotes. A string
    /// without a scheme is a file path — `URL(string:)` would happily build a
    /// schemeless URL from it that no application can open (ghostty#8763) —
    /// so those resolve via the file-URL initializer, with `~` expanded.
    static func resolvedOpenTarget(_ string: String) -> URL {
        if let candidate = URL(string: string), candidate.scheme != nil {
            return candidate
        }
        return URL(fileURLWithPath: (string as NSString).standardizingPath)
    }

    private static func openURL(_ string: String, kind: ghostty_action_open_url_kind_e) {
        let url = resolvedOpenTarget(string)
        // `.text` asks for the payload to be *viewed as text* (scrollback
        // dumps land here): prefer the default app for the file's extension,
        // then the system plain-text editor — same order as Ghostty.app.
        // `.html`/`.unknown` just go to the default handler.
        if kind == GHOSTTY_ACTION_OPEN_URL_KIND_TEXT, let editor = defaultTextEditor(for: url) {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func defaultTextEditor(for url: URL) -> URL? {
        let byExtension = UTType(filenameExtension: url.pathExtension)
            .flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        return byExtension ?? NSWorkspace.shared.urlForApplication(toOpen: .plainText)
    }

    /// Serve a clipboard read. Macterm resolves every read to TEXT (file URLs
    /// become escaped paths, raw images become a temp-PNG path — see
    /// `readPasteboardText`), so a request is served only when it asks for a
    /// text representation; paste and OSC 52 reads request exactly
    /// `text/plain` (apprt/embedded.zig normalizes text-like Kitty mimes to it
    /// too). The Zig side frees the request state unless STARTED is returned,
    /// and a STARTED request must be completed — here that happens
    /// synchronously via `completeClipboardRequest`.
    func readClipboard(
        ud: UnsafeMutableRawPointer?,
        location _: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?,
        mimes: UnsafePointer<UnsafePointer<CChar>?>?,
        mimesLen: Int,
        list: Bool
    ) -> ghostty_clipboard_read_result_e {
        // `ghostty_surface_complete_clipboard_request`'s surface parameter is
        // non-null on the Zig side; a request completing during surface
        // teardown (nil `surface`) is UB, not a graceful no-op. Guard it.
        guard let view = surfaceView(from: ud), let surface = view.surface else {
            return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
        }

        var wantsText = false
        if let mimes {
            for i in 0 ..< mimesLen {
                guard let ptr = mimes[i] else { continue }
                if String(cString: ptr).hasPrefix("text/") {
                    wantsText = true
                    break
                }
            }
        }
        let text: String? = wantsText ? Self.readPasteboardText() : nil

        if wantsText {
            // Record the resolved payload, not just the Command-V key code: an
            // empty/whitespace clipboard must not make a later blank Return
            // look like a nonempty agent submission.
            //
            // Dispatched async BEFORE the synchronous completion below, which
            // is the ordering the evidence depends on: the main queue runs the
            // record after this callback returns — so after the paste has
            // reached the surface — but still before any Return the user types
            // next. Moving it after the completion call, or making it
            // synchronous, breaks that.
            let recorded = text ?? ""
            DispatchQueue.main.async { view.surfaceDidPasteText(recorded) }
        }

        // Nothing to serve and no listing requested: the read has nothing to
        // complete with (returning non-STARTED tells the Zig side to free the
        // request instead of waiting for a completion).
        if text == nil, !list {
            return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE
        }

        Self.completeClipboardRequest(
            surface,
            text: text,
            listsTextPlain: list && Self.hasPasteboardContent(),
            state: state
        )
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Complete a clipboard read with an optional text payload over the
    /// `ghostty_clipboard_complete_s` wire struct. Synchronous — the C memory
    /// only has to outlive the call — so the strings are borrowed
    /// (`withCString`) rather than copied to the heap.
    private static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        text: String?,
        listsTextPlain: Bool,
        state: UnsafeMutableRawPointer?,
        confirmed: Bool = false
    ) {
        "text/plain".withCString { mimePtr in
            func finish(_ contents: UnsafePointer<ghostty_clipboard_content_s>?, _ count: Int) {
                var availableEntry: UnsafePointer<CChar>? = mimePtr
                withUnsafePointer(to: &availableEntry) { availableBase in
                    var complete = ghostty_clipboard_complete_s(
                        contents: contents,
                        contents_len: count,
                        available: listsTextPlain ? availableBase : nil,
                        available_len: listsTextPlain ? 1 : 0,
                        confirmed: confirmed,
                        remember: false
                    )
                    ghostty_surface_complete_clipboard_request(surface, &complete, state)
                }
            }
            if let text {
                text.withCString { textPtr in
                    var content = ghostty_clipboard_content_s(
                        mime: mimePtr,
                        data: textPtr,
                        len: text.utf8.count
                    )
                    withUnsafePointer(to: &content) { finish($0, 1) }
                }
            } else {
                finish(nil, 0)
            }
        }
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
            pruneOldPasteImages(in: dir)
            try data.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }

    /// Best-effort prune of pasted-image temp PNGs older than a day, so the
    /// per-paste files can't accumulate unboundedly. Errors are ignored — this
    /// is opportunistic housekeeping, not a correctness path.
    private static func pruneOldPasteImages(in dir: URL, olderThan maxAge: TimeInterval = 86400) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for entry in entries where entry.pathExtension.lowercased() == "png" {
            guard let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            else { continue }
            if modified < cutoff { try? FileManager.default.removeItem(at: entry) }
        }
    }

    /// A clipboard READ that libghostty's policy says needs user confirmation
    /// (e.g. OSC 52 with `clipboard-read = ask`). Macterm's long-standing
    /// behavior is to approve reads without a prompt (only WRITES prompt — see
    /// `confirmAndWriteClipboard`), so complete with the confirm payload's own
    /// contents verbatim. Synchronous, so the borrowed C memory stays valid
    /// for the duration; a payload we can't honor is denied rather than
    /// dropped, because the Zig side keeps the request state alive waiting
    /// for one of the two calls.
    func confirmReadClipboard(
        ud: UnsafeMutableRawPointer?,
        confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
        state: UnsafeMutableRawPointer?
    ) {
        guard let surface = surface(from: ud) else { return }
        guard let confirm else {
            ghostty_surface_deny_clipboard_request(surface, state)
            return
        }
        let c = confirm.pointee
        var complete = ghostty_clipboard_complete_s(
            contents: c.contents,
            contents_len: c.contents_len,
            available: c.available,
            available_len: c.available_len,
            confirmed: true,
            remember: false
        )
        ghostty_surface_complete_clipboard_request(surface, &complete, state)
    }

    func writeClipboard(
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: UInt,
        location _: ghostty_clipboard_e,
        confirm: Bool
    ) {
        guard let content, len > 0 else { return }
        // macOS has no separate X11-style selection clipboard, so both
        // STANDARD and SELECTION target the general pasteboard (matching
        // upstream Ghostty on macOS) — hence `location` is intentionally
        // ignored here.
        for item in UnsafeBufferPointer(start: content, count: Int(len)) {
            guard let data = item.data, let mime = item.mime, item.len > 0,
                  String(cString: mime).hasPrefix("text/plain")
            else { continue }
            // The wire data is length-delimited and not necessarily
            // NUL-terminated (binary-safe since the clipboard API rework).
            guard let string = String(
                data: Data(bytes: data, count: item.len),
                encoding: .utf8
            )
            else { continue }
            // libghostty asks the host to CONFIRM before applying an OSC 52
            // write (a remote/TUI program overwriting the user's clipboard).
            // Honor it: prompt before clobbering, instead of writing silently.
            if confirm {
                confirmAndWriteClipboard(string)
            } else {
                Self.setPasteboardString(string)
            }
            return
        }
    }

    private static func setPasteboardString(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Guards against a program spamming OSC 52 to stack unbounded modal
    /// alerts: while one confirm dialog is up, further confirm-required writes
    /// are dropped rather than queued. `@MainActor`-isolated (accessed only on
    /// the main queue) so it's concurrency-safe under Swift 6.
    @MainActor
    private static var clipboardConfirmInFlight = false

    /// Prompt before applying a confirm-required OSC 52 clipboard write, so a
    /// remote/TUI program can't silently overwrite the user's clipboard.
    private func confirmAndWriteClipboard(_ string: String) {
        DispatchQueue.main.async {
            // We're on the main queue (the dispatch above), so it's safe to
            // touch the @MainActor-isolated guard and present the alert.
            MainActor.assumeIsolated {
                // A looping TUI could emit OSC 52 repeatedly; only ever show
                // one prompt at a time, and drop the rest instead of stacking
                // modal dialogs (each `runModal` blocks the main loop).
                guard !Self.clipboardConfirmInFlight else { return }
                Self.clipboardConfirmInFlight = true
                defer { Self.clipboardConfirmInFlight = false }
                let alert = NSAlert()
                alert.messageText = "Allow clipboard write?"
                alert.informativeText = """
                A terminal program wants to replace your clipboard with:

                \(Self.clipboardPreview(string))
                """
                alert.addButton(withTitle: "Allow")
                alert.addButton(withTitle: "Deny")
                if alert.runModal() == .alertFirstButtonReturn {
                    Self.setPasteboardString(string)
                }
            }
        }
    }

    /// A short, single-line-ish preview of what would be written, so the user
    /// can judge the prompt instead of allowing blind. Truncated and with
    /// newlines flattened so a huge or multi-line payload can't blow up the
    /// alert.
    private static func clipboardPreview(_ string: String) -> String {
        let flattened = string
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let limit = 200
        return flattened.count > limit ? String(flattened.prefix(limit)) + "…" : flattened
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

    /// Recover the view from a libghostty userdata pointer. Every callback that
    /// needs one goes through here so the unmanaged pointer cast lives in a
    /// single place.
    private func surfaceView(from ud: UnsafeMutableRawPointer?) -> GhosttyTerminalNSView? {
        guard let ud else { return nil }
        return Unmanaged<GhosttyTerminalNSView>.fromOpaque(ud).takeUnretainedValue()
    }

    private func surface(from ud: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        surfaceView(from: ud)?.surface
    }
}
