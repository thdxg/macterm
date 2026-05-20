import AppKit
import Carbon
import SwiftUI

@MainActor
final class QuickTerminalService: NSObject {
    static let shared = QuickTerminalService()
    static let ephemeralProjectID = UUID()

    private(set) var panel: QuickTerminalPanel?
    var panelRef: QuickTerminalPanel? { panel }
    private var hostingView: NSHostingView<QuickTerminalView>?
    private(set) var isVisible = false
    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonEventHandler: EventHandlerRef?
    /// String form of the shortcut we currently have registered with Carbon,
    /// so `userDefaultsDidChange` can detect rebinds and re-register.
    private var lastRegisteredShortcutID: String?
    /// Snapshot of `isEnabled` after the most recent reconcile. Used to detect
    /// flips when `UserDefaults.didChangeNotification` fires, since that
    /// notification doesn't tell us which key changed.
    private var lastKnownEnabled: Bool = Preferences.shared.quickTerminalEnabled
    /// The app that was frontmost just before we showed the quick terminal.
    /// Captured so we can re-activate it on hide if Macterm somehow took over —
    /// without this, dismissing the panel would leave focus on Macterm even
    /// though the user expected to return to whatever they were doing.
    private var previousFrontmostApp: NSRunningApplication?
    let splitState = QuickTerminalSplitState()
    var suppressAutoHide = false
    private var isEnabled: Bool {
        // Read directly from UserDefaults instead of Preferences.shared.
        // Preferences caches the value in a stored property that's only set on
        // init and via its own setter — Settings writes through @AppStorage,
        // which bypasses Preferences entirely. Reading defaults here keeps the
        // service in sync with whatever the toggle's current persisted value
        // actually is.
        UserDefaults.standard.object(forKey: Preferences.Keys.quickTerminalEnabled) as? Bool ?? true
    }

    override private init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(toggle), name: .toggleQuickTerminal, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(autoTilingDidChange),
            name: .autoTilingEnabledDidChange,
            object: nil
        )
        // Observe UserDefaults broadly so we hot-reload no matter who flips the
        // toggle. Settings uses @AppStorage which writes through UserDefaults
        // without going through Preferences.shared, so observing the
        // Preferences object would miss those writes. didChangeNotification
        // fires on any key change; we filter by snapshotting the value.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        // Re-apply the blur radius when Ghostty config changes so the visible
        // panel picks up Settings adjustments without needing to be re-shown.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(reapplyBlur),
            name: .mactermConfigDidChange,
            object: nil
        )
        if isEnabled { registerHotKey() }
    }

    @objc
    private func reapplyBlur() {
        guard let panel, isVisible else { return }
        setWindowBackgroundBlur(panel, radius: Preferences.shared.windowBlurRadius)
    }

    @objc
    private func userDefaultsDidChange() {
        // Two unrelated keys we react to: the enable toggle and the hotkey
        // binding. Reconcile both each time since UserDefaults' change
        // notification doesn't tell us which key changed.
        let now = isEnabled
        if now != lastKnownEnabled {
            lastKnownEnabled = now
            if now {
                registerHotKey()
            } else {
                if isVisible { hide() }
                unregisterHotKey()
            }
        }
        // Re-register on hotkey-binding changes so a Settings → Keymaps
        // rebind takes effect immediately, not after restart.
        let currentBindingID = lastRegisteredShortcutID
        let newBindingID = HotkeyRegistry.selectedShortcut(for: .toggleQuickTerminal)?.id
        if now, currentBindingID != newBindingID {
            unregisterHotKey()
            registerHotKey()
        }
    }

    @objc
    private func autoTilingDidChange() {
        guard Preferences.shared.autoTilingEnabled else { return }
        splitState.splitRoot.rebalanced()
    }

    @objc
    func toggle() {
        guard isEnabled else {
            if isVisible { hide() }
            return
        }
        if isVisible { hide() } else { show() }
    }

    func showPanel() {
        guard isEnabled else { return }
        if isVisible {
            panel?.makeKeyAndOrderFront(nil)
            if let focusedID = splitState.focusedPaneID {
                FocusRestoration.restoreFocus(to: focusedID, in: splitState.splitRoot, window: panel)
            }
        } else {
            show()
        }
    }

    // MARK: - Hot key

    private func registerHotKey() {
        // Idempotent: skip if already registered. Without this, toggling the
        // preference repeatedly would leak event handlers and double-fire.
        guard carbonHotKeyRef == nil else { return }
        guard let shortcut = HotkeyRegistry.selectedShortcut(for: .toggleQuickTerminal) else {
            // User cleared the binding — nothing to register. The shortcut
            // is also unavailable in-app; toggling via the palette or menu
            // command still works.
            return
        }

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x4D55_5859)
        hotKeyID.id = 1

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &id
            )
            if id.id == 1 {
                let svc = Unmanaged<QuickTerminalService>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { svc.toggle() }
            }
            return noErr
        }, 1, &spec, selfPtr, &carbonEventHandler)

        RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            Self.carbonModifiers(from: shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &carbonHotKeyRef
        )
        lastRegisteredShortcutID = shortcut.id
    }

    /// Translate Cocoa modifier flags to Carbon's bitmask. Carbon's hot-key
    /// API predates Cocoa and uses its own constants.
    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

    private func unregisterHotKey() {
        if let ref = carbonHotKeyRef {
            UnregisterEventHotKey(ref)
            carbonHotKeyRef = nil
        }
        if let handler = carbonEventHandler {
            RemoveEventHandler(handler)
            carbonEventHandler = nil
        }
        lastRegisteredShortcutID = nil
    }

    // MARK: - Show / Hide

    private func show() {
        let panel = makePanel()
        self.panel = panel
        guard let screen = NSScreen.main else { return }
        let sf = screen.visibleFrame
        let wFrac = Preferences.shared.quickTerminalWidthFraction
        let hFrac = Preferences.shared.quickTerminalHeightFraction
        let w = sf.width * wFrac, h = sf.height * hFrac
        panel.setFrame(NSRect(x: sf.minX + (sf.width - w) / 2, y: sf.minY + (sf.height - h) / 2, width: w, height: h), display: false)

        let view = QuickTerminalView(state: splitState)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)
        hostingView = hosting

        // Capture the currently-frontmost app *before* showing so we can put
        // focus back on it when the panel hides. The `.nonactivatingPanel`
        // styleMask plus `canBecomeKey` lets the panel receive keyboard input
        // without activating Macterm — the same trick Spotlight and Ghostty's
        // own quick terminal use. We deliberately do NOT call NSApp.activate()
        // here; doing so would steal focus from whatever the user was just
        // working in.
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousFrontmostApp = frontmost
        }
        panel.makeKeyAndOrderFront(nil)
        // Apply the current blur radius (0 = no blur) for this panel session.
        setWindowBackgroundBlur(panel, radius: Preferences.shared.windowBlurRadius)
        if let focusedID = splitState.focusedPaneID {
            FocusRestoration.restoreFocus(to: focusedID, in: splitState.splitRoot, window: panel)
        }
        isVisible = true
    }

    /// Refocus a pane after a close — retries briefly to wait for the new view.
    func refocusPane(_ paneID: UUID) {
        guard let panel, isVisible else { return }
        FocusRestoration.restoreFocus(to: paneID, in: splitState.splitRoot, window: panel)
    }

    private func hide() {
        panel?.orderOut(nil)
        hostingView?.removeFromSuperview()
        hostingView = nil
        panel = nil
        isVisible = false
        // Belt-and-suspenders: if Macterm somehow ended up frontmost while the
        // panel was visible (e.g. the user clicked the dock icon, or another
        // code path called NSApp.activate), bounce focus back to whoever was
        // active before. Skips when Macterm wasn't frontmost to begin with —
        // i.e. the common case where .nonactivatingPanel kept us in the
        // background and there's nothing to restore.
        if let prev = previousFrontmostApp,
           NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Bundle.main.bundleIdentifier
        {
            prev.activate()
        }
        previousFrontmostApp = nil
    }

    private func makePanel() -> QuickTerminalPanel {
        let p = QuickTerminalPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentView = NSView()
        return p
    }
}

// MARK: - Split state

/// Thin wrapper around a single `TerminalTab` that the quick terminal uses as
/// its split tree. Delegates split/resize/close to `TerminalTab` so the main
/// window and quick terminal share the same mutation logic.
@MainActor @Observable
final class QuickTerminalSplitState {
    var tab: TerminalTab
    var pendingClosePaneID: UUID?

    var splitRoot: SplitNode {
        get { tab.splitRoot }
        set { tab.splitRoot = newValue }
    }

    var focusedPaneID: UUID? {
        get { tab.focusedPaneID }
        set { tab.focusedPaneID = newValue }
    }

    init() {
        tab = TerminalTab(projectPath: NSHomeDirectory(), projectID: QuickTerminalService.ephemeralProjectID)
    }

    func focusPane(_ paneID: UUID) {
        tab.focusPane(paneID)
    }

    func requestClosePane(_ paneID: UUID) {
        let needs = tab.splitRoot.findPane(id: paneID)?.nsView?.needsConfirmQuit() ?? false
        if needs {
            pendingClosePaneID = paneID
            presentConfirmAlert()
            return
        }
        closePane(paneID)
    }

    func confirmPendingClose() {
        guard let id = pendingClosePaneID else { return }
        pendingClosePaneID = nil
        closePane(id)
    }

    func cancelPendingClose() {
        pendingClosePaneID = nil
    }

    private func presentConfirmAlert() {
        QuickTerminalService.shared.suppressAutoHide = true
        let alert = NSAlert()
        alert.messageText = "Close running process?"
        alert.informativeText = "A process is still running in this pane. Close it anyway?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            confirmPendingClose()
        } else {
            cancelPendingClose()
        }
        if let panel = QuickTerminalService.shared.panelRef {
            panel.makeKeyAndOrderFront(nil)
            if let focusedID = focusedPaneID,
               let view = tab.splitRoot.findPane(id: focusedID)?.nsView
            {
                panel.makeFirstResponder(view)
            }
        }
        DispatchQueue.main.async {
            QuickTerminalService.shared.suppressAutoHide = false
        }
    }

    func split(paneID: UUID, direction: SplitDirection) {
        tab.split(paneID: paneID, direction: direction)
    }

    func resize(_ direction: PaneFocusDirection, delta: CGFloat = 0.03) {
        tab.resize(direction, delta: delta)
    }

    func closePane(_ paneID: UUID) {
        switch tab.removePane(paneID) {
        case .onlyPaneLeft:
            // Replace the whole tab with a fresh one — the quick terminal should
            // always have at least one pane, but we fully reset so the prior
            // pane's surface is torn down (removePane already destroyed it).
            tab = TerminalTab(projectPath: NSHomeDirectory(), projectID: QuickTerminalService.ephemeralProjectID)
        case .removed,
             .notFound:
            break
        }
        if let newID = focusedPaneID {
            QuickTerminalService.shared.refocusPane(newID)
        }
    }
}

// MARK: - Panel

final class QuickTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        // Don't auto-hide while a confirmation alert is pending or is being torn down.
        if QuickTerminalService.shared.suppressAutoHide { return }
        if QuickTerminalService.shared.splitState.pendingClosePaneID != nil { return }
        if QuickTerminalService.shared.isVisible {
            QuickTerminalService.shared.toggle()
        }
    }
}

// MARK: - Views

private struct QuickTerminalView: View {
    @Bindable var state: QuickTerminalSplitState

    var body: some View {
        let renderedNode: SplitNode = {
            if let zoomID = state.tab.zoomedPaneID, let pane = state.splitRoot.findPane(id: zoomID) {
                return .pane(pane)
            }
            return state.splitRoot
        }()
        SplitTreeView(
            node: renderedNode,
            focusedPaneID: state.focusedPaneID,
            zoomedPaneID: state.tab.zoomedPaneID,
            isActiveProject: true,
            projectID: QuickTerminalService.ephemeralProjectID,
            onFocusPane: { state.focusPane($0) },
            onSplit: { paneID, dir in state.split(paneID: paneID, direction: dir) },
            onClosePane: { state.closePane($0) },
            onToggleZoom: { state.tab.toggleZoom(paneID: $0) }
        )
        .id(renderedNode.id)
        .background(MactermTheme.bgWithOpacity)
        .overlay(alignment: .topTrailing) {
            if let zoomID = state.tab.zoomedPaneID {
                ZoomIndicator(onExit: { state.tab.toggleZoom(paneID: zoomID) })
                    .padding(8)
                    .transition(.opacity)
            }
        }
    }
}
