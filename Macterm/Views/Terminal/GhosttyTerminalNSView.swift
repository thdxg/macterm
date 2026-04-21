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
    var onTitleChange: ((String) -> Void)?
    var onFocus: (() -> Void)?
    var onProcessExit: (() -> Void)?
    var onSplitRequest: ((SplitDirection, SplitPosition) -> Void)?
    var onSearchStart: ((String?) -> Void)?
    var onSearchEnd: (() -> Void)?
    var onSearchTotal: ((Int?) -> Void)?
    var onSearchSelected: ((Int?) -> Void)?
    var isFocused: Bool = false
    var currentPwd: String?

    private var _markedRange: NSRange = .init(location: NSNotFound, length: 0)
    private var _selectedRange: NSRange = .init(location: NSNotFound, length: 0)
    private var keyTextAccumulator: [String] = []
    private var currentKeyEvent: NSEvent?

    init(workingDirectory: String) {
        self.workingDirectory = workingDirectory
        super.init(frame: .zero)
        wantsLayer = true
        setupTrackingArea()
        Self.liveViews.add(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.framebufferOnly = false
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.needsDisplayOnBoundsChange = true
        layer.presentsWithTransaction = false
        return layer
    }

    override var wantsUpdateLayer: Bool { true }

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
        config.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
        config.context = GHOSTTY_SURFACE_CONTEXT_SPLIT

        workingDirectory.withCString { cwd in
            config.working_directory = cwd
            surface = ghostty_surface_new(app, &config)
        }
        guard let surface else { return }

        let scale = Double(window?.backingScaleFactor ?? 2.0)
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(backingSize.width), UInt32(backingSize.height))

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
    }

    deinit {
        if let surface { ghostty_surface_free(surface) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
        if let metalLayer = layer as? CAMetalLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            metalLayer.contentsScale = CGFloat(scale)
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
        interpretKeyEvents([event])
        currentKeyEvent = nil

        var ke = buildKeyEvent(from: event, action: action)
        ke.consumed_mods = consumedMods(flags)
        ke.composing = hasMarkedText() || hadMarkedText

        if !keyTextAccumulator.isEmpty, !ke.composing {
            for text in keyTextAccumulator {
                text.withCString { ke.text = $0
                    _ = ghostty_surface_key(surface, ke)
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
        guard let surface else { return }
        var ke = buildKeyEvent(from: event, action: isFlagPress(event) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
        ke.text = nil
        _ = ghostty_surface_key(surface, ke)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isAppShortcut(event) { return false }
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
        guard let surface else { return }
        var scrollMods: ghostty_input_scroll_mods_t = 0
        if event.hasPreciseScrollingDeltas { scrollMods |= 1 }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, scrollMods)
    }

    // MARK: - Context menu

    private func presentContextMenu(with event: NSEvent) {
        let menu = NSMenu(title: "Terminal")
        let paste = NSMenuItem(title: "Paste", action: #selector(handlePaste), keyEquivalent: "")
        paste.target = self
        paste.isEnabled = NSPasteboard.general.string(forType: .string).map { !$0.isEmpty } ?? false
        menu.addItem(paste)
        menu.addItem(.separator())
        addSplitItem(menu, "Split Right", .horizontal, .second)
        addSplitItem(menu, "Split Left", .horizontal, .first)
        addSplitItem(menu, "Split Down", .vertical, .second)
        addSplitItem(menu, "Split Up", .vertical, .first)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func addSplitItem(_ menu: NSMenu, _ title: String, _ dir: SplitDirection, _ pos: SplitPosition) {
        let item = NSMenuItem(title: title, action: #selector(handleSplit(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ContextSplit(direction: dir, position: pos)
        menu.addItem(item)
    }

    @objc
    private func handlePaste() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
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
        var m = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
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

    private func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        guard let chars = event.characters(byApplyingModifiers: []),
              let scalar = chars.unicodeScalars.first
        else { return 0 }
        return scalar.value
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
