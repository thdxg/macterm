import AppKit
import GhosttyKit
import QuartzCore

final class GhosttyTerminalNSView: NSView {
    /// Weak registry of every live instance so global operations (e.g. config
    /// reload) can iterate without a central cache.
    @MainActor private static let liveViews = NSHashTable<GhosttyTerminalNSView>.weakObjects()
    @MainActor
    static func allLiveViews() -> [GhosttyTerminalNSView] {
        liveViews.allObjects
    }

    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?
    private let workingDirectory: String
    /// Command to type into the shell once the surface is created (the pane's
    /// declared `run`). nil → no injected input.
    private let command: String?
    /// Shell binary to launch as the surface's program. nil → libghostty's
    /// default (resolved from the ghostty config / login shell).
    private let shell: String?
    /// Extra environment variables for the spawned shell.
    private let env: [String: String]?

    /// Heap buffers backing the `const char*` fields of the surface config —
    /// notably `initial_input`, which libghostty writes to the pty
    /// asynchronously after the child spawns, so the buffer must outlive
    /// `ghostty_surface_new`. Retained here and freed in `destroySurface`.
    nonisolated(unsafe) private var configCStrings: [UnsafeMutablePointer<CChar>] = []

    /// The most recent title the surface reported (OSC 0/2 / `SET_TITLE`).
    /// Remembered so re-wiring `onTitleChange` (when SwiftUI's `configure`
    /// adopts a warmed surface) replays the latest title once — the surface
    /// may have reported it before the callback was wired.
    private var lastReportedTitle: String?

    /// Fires on each OSC title with the reported string. Whether the string
    /// is *used* for naming is the pane's call (`Pane.receiveReportedTitle`
    /// gates on the foreground process); every arrival also marks a command
    /// boundary that drives a foreground-process refresh.
    var onTitleChange: ((String) -> Void)? {
        didSet {
            if let title = lastReportedTitle { onTitleChange?(title) }
        }
    }

    /// Deliver a title reported by libghostty (OSC 0/2 / `SET_TITLE`).
    /// Called by `GhosttyCallbacks`.
    func surfaceDidReportTitle(_ title: String) {
        lastReportedTitle = title
        onTitleChange?(title)
    }

    func surfaceDidReportProgress(running: Bool) {
        if running {
            onProgressStarted?()
        } else {
            onProgressFinished?()
        }
    }

    func surfaceDidUpdateScrollbar(total: UInt64, offset: UInt64, len: UInt64) {
        let snapshot = ScrollbarSnapshot(total: total, offset: offset, len: len)
        if let lastScrollbarSnapshot, total > lastScrollbarSnapshot.total {
            onTerminalActivity?()
        }
        lastScrollbarSnapshot = snapshot
        onScrollbarUpdate?(total, offset, len)
    }

    var onFocus: (() -> Void)?
    var onInteraction: (() -> Void)?
    var onProcessExit: (() -> Void)?
    var onSplitRequest: ((SplitDirection, SplitPosition) -> Void)?
    var onZoomRequest: (() -> Void)?
    var isZoomed: Bool = false
    var onSearchStart: ((String?) -> Void)?
    var onSearchEnd: (() -> Void)?
    var onSearchTotal: ((Int?) -> Void)?
    var onSearchSelected: ((Int?) -> Void)?
    var onDesktopNotification: ((String, String) -> Void)?
    var onCommandFinished: ((Int16, UInt64) -> Void)?
    var onProgressStarted: (() -> Void)?
    var onProgressFinished: (() -> Void)?
    var onTerminalActivity: (() -> Void)?
    /// libghostty pushes scrollback geometry (all values in rows) whenever the
    /// viewport, scrollback size, or visible row count changes.
    /// `(total, offset, len)`: total rows including scrollback, the first
    /// visible row (0 = top of history), and the visible row count.
    var onScrollbarUpdate: ((UInt64, UInt64, UInt64) -> Void)?
    /// Gives the hosting `SurfaceScrollView` first chance to handle scrollback
    /// wheel/trackpad events with its iTerm-style line accumulator. It declines
    /// when there's no scrollback to move through (so alternate-screen apps
    /// like less/vim fall through to libghostty for mouse reporting). Return
    /// false to let libghostty handle the event directly.
    var onScrollWheel: ((NSEvent) -> Bool)?
    var isFocused: Bool = false
    var currentPwd: String?

    private var lastScrollbarSnapshot: ScrollbarSnapshot?

    private struct ScrollbarSnapshot: Equatable {
        let total: UInt64
        let offset: UInt64
        let len: UInt64
    }

    private var _markedRange: NSRange = .init(location: NSNotFound, length: 0)
    private var _selectedRange: NSRange = .init(location: NSNotFound, length: 0)
    private var keyTextAccumulator: [String] = []
    private var currentKeyEvent: NSEvent?

    init(workingDirectory: String, command: String? = nil, shell: String? = nil, env: [String: String]? = nil) {
        self.workingDirectory = workingDirectory
        self.command = command
        self.shell = shell
        self.env = env
        super.init(frame: .zero)
        setupTrackingArea()
        registerForDraggedTypes(Array(Self.dropTypes))
        Self.liveViews.add(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Surface lifecycle

    private var pendingSurfaceCreation = false

    /// Once destroySurface() has been called this view is "retired": it should
    /// never spontaneously recreate a surface (e.g. from viewDidMoveToWindow or
    /// from a stray updateNSView during SwiftUI teardown).
    private var isDestroyed = false

    func createSurface() {
        guard !isDestroyed else { return }
        guard surface == nil, let app = GhosttyApp.shared.app else { return }
        let backingSize = convertToBacking(bounds).size
        guard backingSize.width > 0, backingSize.height > 0 else {
            pendingSurfaceCreation = true
            return
        }
        pendingSurfaceCreation = false

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        // Every `const char*` field and the env-var array must stay valid for
        // libghostty. `working_directory`/`command` are consumed during spawn,
        // but `initial_input` is written to the pty asynchronously (on a later
        // surface tick, after the child process is up — see the Ghostty config
        // reference: "written to the pty before any other input"). So these
        // buffers must outlive `ghostty_surface_new`, not just the call itself.
        // We `strdup` into heap buffers whose addresses are stable (unlike
        // pointers into a Swift Array, which move when the array grows) and
        // retain them on the instance until `destroySurface` frees them.
        configCStrings.forEach { free($0) }
        configCStrings = []
        func cString(_ s: String) -> UnsafePointer<CChar>? {
            guard let p = strdup(s) else { return nil }
            configCStrings.append(p)
            return UnsafePointer(p)
        }

        config.working_directory = cString(workingDirectory)

        // Shell binary → the surface's program. nil falls back to libghostty's
        // own resolution (which honors the user's ghostty config / login shell).
        if let resolvedShell = shell ?? GhosttyApp.shared.configuredShell {
            config.command = cString(resolvedShell)
        }

        // Declared `run` is typed into the shell verbatim, as if the user had
        // entered it at the prompt. No shell-syntax handling: cwd is set above,
        // not via an injected `cd`.
        if let command, !command.isEmpty {
            config.initial_input = cString(command + "\n")
        }

        // Extra environment variables. The array of key/value structs points at
        // buffers owned above; hold it in a local that outlives the call.
        var envVars: [ghostty_env_var_s] = []
        if let env, !env.isEmpty {
            for (key, value) in env {
                envVars.append(ghostty_env_var_s(key: cString(key), value: cString(value)))
            }
        }

        if envVars.isEmpty {
            surface = ghostty_surface_new(app, &config)
        } else {
            envVars.withUnsafeMutableBufferPointer { buf in
                config.env_vars = buf.baseAddress
                config.env_var_count = buf.count
                surface = ghostty_surface_new(app, &config)
            }
        }
        guard let surface else { return }

        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_surface_set_color_scheme(surface, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)

        if let screen = window?.screen ?? NSScreen.main,
           let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        {
            ghostty_surface_set_display_id(surface, displayID)
        }
        ghostty_surface_set_focus(surface, isFocused)
    }

    func destroySurface() {
        isDestroyed = true
        if let surface { ghostty_surface_free(surface) }
        surface = nil
        configCStrings.forEach { free($0) }
        configCStrings = []
    }

    /// PID of the foreground process running in this surface's pty (libghostty's
    /// `tcgetpgrp` on the pty master), or nil if there's no surface. When the
    /// user is idle at a shell prompt this is the shell itself; while a command
    /// runs it's that command. Used by `ProcessInspector` to capture a pane's
    /// running command for `saveLayout`.
    var foregroundPID: pid_t? {
        guard let surface else { return nil }
        let pid = ghostty_surface_foreground_pid(surface)
        return pid != 0 ? pid_t(pid) : nil
    }

    /// The slave tty path for this surface's pty, used by `ProcessInspector` to
    /// read terminal input mode (canonical shell command vs raw/cbreak TUI).
    var ttyName: String? {
        guard let surface else { return nil }
        let tty = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(tty) }
        guard let ptr = tty.ptr, tty.len > 0 else { return nil }
        let bytes = UnsafeBufferPointer(start: ptr, count: Int(tty.len)).map { UInt8(bitPattern: $0) }
        guard let name = String(bytes: bytes, encoding: .utf8), !name.isEmpty else { return nil }
        return name
    }

    deinit {
        if let surface { ghostty_surface_free(surface) }
        configCStrings.forEach { free($0) }
        for token in windowObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    nonisolated(unsafe) private var windowObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Tear down previous window's observers.
        for token in windowObservers {
            NotificationCenter.default.removeObserver(token)
        }
        windowObservers.removeAll()

        guard let window else { return }
        if surface == nil {
            createSurface()
        } else {
            // Reconnect existing surface to the new window
            let scale = Double(window.backingScaleFactor)
            ghostty_surface_set_content_scale(surface, scale, scale)
            let size = convertToBacking(bounds).size
            if size.width > 0, size.height > 0 {
                ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
            }
            ghostty_surface_set_focus(surface, isFocused)
        }
        updateMetalLayerSize()

        // The per-view `viewDidChangeBackingProperties` override doesn't reliably
        // fire when the window moves between displays of different DPI. Listen
        // on the window directly so the surface picks up the new scale even
        // when AppKit doesn't propagate the call to every layer-backed subview.
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMetalLayerSize() }
        }
        let backing = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeBackingPropertiesNotification,
            object: window,
            queue: .main,
            using: handler
        )
        let screen = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: window,
            queue: .main,
            using: handler
        )
        windowObservers = [backing, screen]
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if pendingSurfaceCreation { createSurface() }
        updateMetalLayerSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMetalLayerSize()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let surface else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_surface_set_color_scheme(surface, isDark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
    }

    private func updateMetalLayerSize() {
        guard let surface, window != nil else { return }
        let scaledSize = convertToBacking(bounds).size
        guard scaledSize.width > 0, scaledSize.height > 0 else { return }
        let scale = Double(window?.backingScaleFactor ?? 2.0)
        if let liveLayer = layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            liveLayer.contentsScale = CGFloat(scale)
            CATransaction.commit()
        }
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(scaledSize.width), UInt32(scaledSize.height))
    }

    // MARK: - App shortcut detection

    /// System shortcuts that should always pass through to macOS.
    private static let systemKeys: Set<String> = ["q", "h", "m", ","]

    private func isAppShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        // Always let system Cmd shortcuts through
        if flags == .command, Self.systemKeys.contains(key) { return true }
        // Cmd+1-9 for tab selection
        if flags == .command, let n = Int(key), (1 ... 9).contains(n) { return true }
        // Check all configurable hotkey actions
        if HotkeyAction.allCases.contains(where: { HotkeyRegistry.matches(event, action: $0) }) { return true }
        return false
    }

    func needsConfirmQuit() -> Bool {
        guard let surface else { return false }
        return ghostty_surface_needs_confirm_quit(surface)
    }

    /// Cell height in points (not backing pixels). libghostty reports cell
    /// dimensions in backing pixels; divide by the backing scale so callers
    /// working in AppKit's point space (e.g. the scroll view's document view)
    /// get the right value. Returns 0 if the surface isn't ready.
    var cellHeightPoints: CGFloat {
        guard let surface else { return 0 }
        let size = ghostty_surface_size(surface)
        guard size.cell_height_px > 0 else { return 0 }
        let scale = window?.backingScaleFactor ?? 2.0
        return CGFloat(size.cell_height_px) / scale
    }

    func notifySurfaceFocused() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, true)
    }

    func notifySurfaceUnfocused() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, false)
    }

    // MARK: - First responder

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result, let surface {
            ghostty_surface_set_focus(surface, true)
            onFocus?()
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result, let surface { ghostty_surface_set_focus(surface, false) }
        return result
    }

    // MARK: - Tracking area

    private var currentTrackingArea: NSTrackingArea?

    private func setupTrackingArea() {
        if let existing = currentTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        currentTrackingArea = area
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        setupTrackingArea()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        onInteraction?()
        guard let surface else { super.keyDown(with: event)
            return
        }
        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.control), !flags.contains(.command), !flags.contains(.option), !hasMarkedText() {
            if isAppShortcut(event) { return }
            var ke = buildKeyEvent(from: event, action: action)
            let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
            if text.isEmpty {
                ke.text = nil
                _ = ghostty_surface_key(surface, ke)
            } else {
                text.withCString { ke.text = $0
                    _ = ghostty_surface_key(surface, ke)
                }
            }
            return
        }

        if flags.contains(.command) {
            if isAppShortcut(event) { return }
            var ke = buildKeyEvent(from: event, action: action)
            ke.text = nil
            _ = ghostty_surface_key(surface, ke)
            return
        }

        let hadMarkedText = hasMarkedText()
        currentKeyEvent = event
        keyTextAccumulator = []
        // Ask libghostty which modifier flags to use for *translation* — when
        // macos-option-as-alt is on, it returns flags with Option stripped.
        // We then build a synthetic NSEvent whose `characters` come from
        // `characters(byApplyingModifiers:)` with those flags, so Option+b
        // yields "b" instead of "∫" when routed through interpretKeyEvents.
        let translationEvent = translatedEvent(for: event)
        interpretKeyEvents([translationEvent])
        currentKeyEvent = nil

        var ke = buildKeyEvent(from: event, action: action)
        // consumed_mods tells libghostty which modifiers were "used up" to
        // produce the translated text. We use the translation event's flags
        // (Alt stripped when option-as-alt is on), minus ctrl/command which
        // never contribute to text translation. This matches Ghostty's own
        // app: with option-as-alt on, Alt is *not* consumed, so libghostty
        // encodes ESC+b for Option+b, letting editors like Helix see it.
        ke.consumed_mods = consumedMods(translationEvent.modifierFlags)
        ke.composing = hasMarkedText() || hadMarkedText

        // Accumulator content is text the IME *committed* via `insertText`
        // during interpretKeyEvents. Send it regardless of `composing` state:
        // committing happens precisely when the IME finishes a syllable, which
        // may overlap with a new composition starting (so `composing == true`
        // here even though this specific text is finalized). Without this,
        // Korean / Japanese / Chinese input drops every committed character.
        // The text itself carries no composing flag since it's already final.
        if !keyTextAccumulator.isEmpty {
            var commitKE = ke
            commitKE.composing = false
            for text in keyTextAccumulator {
                text.withCString { commitKE.text = $0
                    _ = ghostty_surface_key(surface, commitKE)
                }
            }
        } else if !hasMarkedText() {
            let text = filterSpecial(event.characters ?? "")
            if !text.isEmpty, !ke.composing {
                text.withCString { ke.text = $0
                    _ = ghostty_surface_key(surface, ke)
                }
            } else {
                ke.consumed_mods = GHOSTTY_MODS_NONE
                ke.text = nil
                _ = ghostty_surface_key(surface, ke)
            }
        }
    }

    override func doCommand(by selector: Selector) {}

    override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        var ke = buildKeyEvent(from: event, action: GHOSTTY_ACTION_RELEASE)
        ke.text = nil
        _ = ghostty_surface_key(surface, ke)
    }

    override func flagsChanged(with event: NSEvent) {
        onInteraction?()
        guard let surface else { return }
        var ke = buildKeyEvent(from: event, action: isFlagPress(event) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
        ke.text = nil
        _ = ghostty_surface_key(surface, ke)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isAppShortcut(event) { return false }
        onInteraction?()
        guard window?.firstResponder === self || window?.firstResponder === inputContext else { return false }
        guard event.type == .keyDown, let surface else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return false }
        var ke = buildKeyEvent(from: event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
        ke.text = nil
        if ghostty_surface_key_is_binding(surface, ke, nil) {
            _ = ghostty_surface_key(surface, ke)
            return true
        }
        return false
    }

    // MARK: - Mouse

    private func mousePoint(from event: NSEvent) -> NSPoint {
        let local = convert(event.locationInWindow, from: nil)
        return NSPoint(x: local.x, y: bounds.height - local.y)
    }

    override func mouseDown(with event: NSEvent) {
        onInteraction?()
        guard let surface else { return }
        window?.makeFirstResponder(self)
        ghostty_surface_set_focus(surface, true)
        onFocus?()
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods(event))
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        onInteraction?()
        guard let surface else { return }
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods(event)) {
            presentContextMenu(with: event)
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
        if !ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods(event)) {
            super.rightMouseUp(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        onInteraction?()
        guard let surface else { return }

        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            // Match Ghostty's macOS frontend: precise trackpad/Magic Mouse
            // deltas are valid but feel slow at 1x because terminals scroll in
            // rows instead of continuous document pixels.
            x *= 2
            y *= 2
        }

        if !ghostty_surface_mouse_captured(surface), onScrollWheel?(event) == true {
            return
        }

        ghostty_surface_mouse_scroll(surface, x, y, scrollMods(for: event))
    }

    private func scrollMods(for event: NSEvent) -> ghostty_input_scroll_mods_t {
        var scrollMods: ghostty_input_scroll_mods_t = 0
        if event.hasPreciseScrollingDeltas { scrollMods |= 1 }
        scrollMods |= scrollMomentum(for: event.momentumPhase) << 1
        return scrollMods
    }

    private func scrollMomentum(for phase: NSEvent.Phase) -> ghostty_input_scroll_mods_t {
        switch phase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
    }

    // MARK: - Context menu

    private func presentContextMenu(with event: NSEvent) {
        let menu = NSMenu(title: "Terminal")
        let paste = NSMenuItem(title: "Paste", action: #selector(handlePaste), keyEquivalent: "")
        paste.target = self
        paste.isEnabled = GhosttyCallbacks.hasPasteboardContent()
        menu.addItem(paste)
        menu.addItem(.separator())
        addSplitItem(menu, "Split Right", .horizontal, .second)
        addSplitItem(menu, "Split Left", .horizontal, .first)
        addSplitItem(menu, "Split Down", .vertical, .second)
        addSplitItem(menu, "Split Up", .vertical, .first)
        if onZoomRequest != nil {
            menu.addItem(.separator())
            let zoom = NSMenuItem(
                title: isZoomed ? "Restore Pane" : "Zoom Pane",
                action: #selector(handleZoom),
                keyEquivalent: ""
            )
            zoom.target = self
            menu.addItem(zoom)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc
    private func handleZoom() {
        onZoomRequest?()
    }

    private func addSplitItem(_ menu: NSMenu, _ title: String, _ dir: SplitDirection, _ pos: SplitPosition) {
        let item = NSMenuItem(title: title, action: #selector(handleSplit(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ContextSplit(direction: dir, position: pos)
        menu.addItem(item)
    }

    @objc
    private func handlePaste() {
        onInteraction?()
        guard let text = GhosttyCallbacks.readPasteboardText() else { return }
        window?.makeFirstResponder(self)
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @objc
    private func handleSplit(_ sender: NSMenuItem) {
        guard let split = sender.representedObject as? ContextSplit else { return }
        onSplitRequest?(split.direction, split.position)
    }

    private final class ContextSplit: NSObject {
        let direction: SplitDirection
        let position: SplitPosition
        init(direction: SplitDirection, position: SplitPosition) {
            self.direction = direction
            self.position = position
        }
    }

    // MARK: - Search

    func sendSearchQuery(_ needle: String) {
        guard let surface else { return }
        let action = "search:\(needle)"
        ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    func navigateSearch(direction: SearchDirection) {
        guard let surface else { return }
        let action = "navigate_search:\(direction.rawValue)"
        ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    func endSearch() {
        guard let surface else { return }
        let action = "end_search"
        ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    func startSearch() {
        guard let surface else { return }
        ghostty_surface_binding_action(surface, "start_search", 12)
    }

    enum SearchDirection: String { case next, previous }

    // MARK: - Key event helpers

    private func buildKeyEvent(from event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var ke = ghostty_input_key_s()
        ke.action = action
        ke.keycode = UInt32(event.keyCode)
        ke.mods = mods(event)
        ke.consumed_mods = GHOSTTY_MODS_NONE
        ke.composing = false
        ke.text = nil
        ke.unshifted_codepoint = unshiftedCodepoint(from: event)
        return ke
    }

    private func consumedMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        // ctrl/command never contribute to text translation; assume everything
        // else did. Matches Ghostty's own app behavior.
        var m = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: m)
    }

    private func mods(_ event: NSEvent) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        let f = event.modifierFlags
        if f.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if f.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if f.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if f.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if f.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        // Side bits: NSEvent's modifierFlags include device-dependent bits
        // (NX_DEVICE{L,R}*KEYMASK) that tell us which physical modifier key was
        // pressed. libghostty needs the side bit to honor macos-option-as-alt =
        // left/right (and the equivalent shift/ctrl/super distinctions). The
        // SIDE bit is "1 = right" and is only meaningful when the base mod is
        // set, so we mark it whenever the right key is down and the left is
        // not — matching how Ghostty's own macOS app reports sides.
        let raw = f.rawValue
        let leftShift: UInt = 0x02, rightShift: UInt = 0x04
        let leftCtrl: UInt = 0x01, rightCtrl: UInt = 0x2000
        let leftAlt: UInt = 0x20, rightAlt: UInt = 0x40
        let leftCmd: UInt = 0x08, rightCmd: UInt = 0x10
        if raw & rightShift != 0, raw & leftShift == 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & rightCtrl != 0, raw & leftCtrl == 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & rightAlt != 0, raw & leftAlt == 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & rightCmd != 0, raw & leftCmd == 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(rawValue: m)
    }

    private func isFlagPress(_ event: NSEvent) -> Bool {
        let f = event.modifierFlags
        switch event.keyCode {
        case 56,
             60: return f.contains(.shift)
        case 58,
             61: return f.contains(.option)
        case 59,
             62: return f.contains(.control)
        case 55,
             54: return f.contains(.command)
        case 57: return f.contains(.capsLock)
        default: return false
        }
    }

    private func filterSpecial(_ text: String) -> String {
        guard let scalar = text.unicodeScalars.first else { return "" }
        let v = scalar.value
        if v < 0x20 || (0xF700 ... 0xF8FF).contains(v) { return "" }
        return text
    }

    /// Builds a synthetic NSEvent whose modifier flags reflect libghostty's
    /// translation policy — with macos-option-as-alt on, Option is stripped so
    /// `characters(byApplyingModifiers:)` returns the unshifted char ("b")
    /// instead of the macOS special char ("∫"). Falls back to the original
    /// event if no rewrite is needed or if NSEvent.keyEvent fails.
    private func translatedEvent(for event: NSEvent) -> NSEvent {
        guard let surface else { return event }
        let originalMods = mods(event)
        let translationModsRaw = ghostty_surface_key_translation_mods(surface, originalMods).rawValue
        var translationFlags = event.modifierFlags
        for (bit, flag) in [
            (GHOSTTY_MODS_SHIFT.rawValue, NSEvent.ModifierFlags.shift),
            (GHOSTTY_MODS_CTRL.rawValue, NSEvent.ModifierFlags.control),
            (GHOSTTY_MODS_ALT.rawValue, NSEvent.ModifierFlags.option),
            (GHOSTTY_MODS_SUPER.rawValue, NSEvent.ModifierFlags.command),
        ] {
            if translationModsRaw & bit != 0 { translationFlags.insert(flag) } else { translationFlags.remove(flag) }
        }
        if translationFlags == event.modifierFlags { return event }
        let translatedChars = event.characters(byApplyingModifiers: translationFlags) ?? ""
        return NSEvent.keyEvent(
            with: event.type,
            location: event.locationInWindow,
            modifierFlags: translationFlags,
            timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            context: nil,
            characters: translatedChars,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }

    private func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        guard event.type == .keyDown || event.type == .keyUp,
              let chars = event.characters(byApplyingModifiers: []),
              let scalar = chars.unicodeScalars.first
        else { return 0 }
        return scalar.value
    }

    // MARK: - Drag & drop

    /// Pasteboard types we accept when something is dragged onto the surface.
    private static let dropTypes: Set<NSPasteboard.PasteboardType> = [.string, .fileURL, .URL]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types, !Set(types).isDisjoint(with: Self.dropTypes) else {
            return []
        }
        // .copy gives the drop the familiar green "+" cursor.
        return .copy
    }

    /// Drops insert the escaped file path(s) / URL at the cursor. File URLs are
    /// shell-escaped individually and space-joined; plain strings are inserted
    /// verbatim (they may be a command the user means to run).
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        let content: String? = if let url = pb.string(forType: .URL) {
            GhosttyCallbacks.shellEscape(url)
        } else if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            urls
                .map { GhosttyCallbacks.shellEscape($0.path(percentEncoded: false)) }
                .joined(separator: " ")
        } else if let str = pb.string(forType: .string) {
            str
        } else {
            nil
        }

        guard let content else { return false }
        // Defer the insert (as Ghostty does) so the drag session fully unwinds
        // before we mutate the terminal buffer.
        DispatchQueue.main.async {
            self.insertText(content, replacementRange: NSRange(location: 0, length: 0))
        }
        return true
    }
}

// MARK: - NSTextInputClient

extension GhosttyTerminalNSView: @preconcurrency NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        _markedRange = NSRange(location: NSNotFound, length: 0)
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
        if currentKeyEvent != nil {
            keyTextAccumulator.append(text)
        } else if let surface {
            text.withCString { ptr in
                var ke = ghostty_input_key_s()
                ke.action = GHOSTTY_ACTION_PRESS
                ke.text = ptr
                _ = ghostty_surface_key(surface, ke)
            }
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let surface else { return }
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        _markedRange = text.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: text.count)
        _selectedRange = selectedRange
        text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.count)) }
    }

    func unmarkText() {
        guard let surface else { return }
        _markedRange = NSRange(location: NSNotFound, length: 0)
        ghostty_surface_preedit(surface, nil, 0)
    }

    func selectedRange() -> NSRange {
        _selectedRange
    }

    func markedRange() -> NSRange {
        _markedRange
    }

    func hasMarkedText() -> Bool {
        _markedRange.location != NSNotFound
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .backgroundColor]
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let viewPt = NSPoint(x: x, y: bounds.height - y)
        let screenPt = window?.convertPoint(toScreen: convert(viewPt, to: nil)) ?? viewPt
        return NSRect(x: screenPt.x, y: screenPt.y - h, width: w, height: h)
    }
}
