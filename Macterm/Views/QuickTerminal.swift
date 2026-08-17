import AppKit
import Carbon
import os
import SwiftUI

private let hotkeyLogger = Logger(subsystem: appBundleID, category: "QuickTerminalHotkey")

/// Orders the quick-terminal panel key + front, absorbing any Objective-C
/// exception AppKit raises mid-ordering, and reports whether the panel made it
/// on screen. Ordering can genuinely throw: ViewBridge's NSRemoteView (the
/// text-input cursor UI hosted inside our windows) raised
/// NSInternalInconsistencyException out of `makeKeyAndOrderFront` on a macOS
/// beta, and uncaught it killed the whole app with no crash report. Callers
/// must skip follow-up work that assumes a visible panel when this returns
/// false.
@MainActor
private func orderPanelFront(_ panel: NSPanel) -> Bool {
    guard let exception = catchingObjCException({ panel.makeKeyAndOrderFront(nil) }) else { return true }
    hotkeyLogger
        .error(
            "makeKeyAndOrderFront raised \(exception.name.rawValue, privacy: .public): \(exception.reason ?? "no reason", privacy: .public)"
        )
    return false
}

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
        Preferences.defaults.object(forKey: Preferences.Keys.quickTerminalEnabled) as? Bool ?? true
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
            if let panel, orderPanelFront(panel), let focusedID = splitState.focusedPaneID {
                FocusRestoration.restoreFocus(to: focusedID, in: splitState.splitRoot, window: panel)
            }
        } else {
            show()
        }
    }

    // MARK: - Hot key

    private func registerHotKey() {
        // Idempotent: skip if EITHER Carbon resource is already installed.
        // Guarding only on `carbonHotKeyRef` (the LAST resource acquired) left
        // a window where a prior failed registration had installed the handler
        // but not the hotkey — re-entry would then install a SECOND handler and
        // orphan the first. Guarding on the handler too closes that.
        guard carbonHotKeyRef == nil, carbonEventHandler == nil else { return }
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
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
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
        guard installStatus == noErr else {
            hotkeyLogger.error("InstallEventHandler failed: \(installStatus, privacy: .public)")
            carbonEventHandler = nil
            return
        }

        let registerStatus = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            Self.carbonModifiers(from: shortcut.modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &carbonHotKeyRef
        )
        guard registerStatus == noErr else {
            // Roll back the handler so state stays all-or-nothing — otherwise a
            // later re-entry would orphan this handler. (The shortcut may be
            // owned by another app; the palette/menu toggle still works.)
            hotkeyLogger.error("RegisterEventHotKey failed: \(registerStatus, privacy: .public)")
            if let handler = carbonEventHandler {
                RemoveEventHandler(handler)
                carbonEventHandler = nil
            }
            carbonHotKeyRef = nil
            return
        }
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
        // Acquire the screen BEFORE creating/assigning the panel: on a no-screen
        // bail we'd otherwise leave `panel` non-nil while `isVisible == false`,
        // so a later toggle would create a second panel and orphan this one.
        guard let screen = NSScreen.main else { return }
        let panel = makePanel()
        self.panel = panel
        let prefs = Preferences.shared
        panel.setFrame(
            QuickTerminalPlacement.frame(
                visibleFrame: screen.visibleFrame,
                widthFraction: prefs.quickTerminalWidthFraction,
                heightFraction: prefs.quickTerminalHeightFraction,
                // A remembered position only applies while dragging is enabled;
                // with the toggle off the panel is always centered, even if a
                // position from an earlier session is still stored.
                position: prefs.quickTerminalDraggingEnabled ? prefs.quickTerminalPosition : nil
            ),
            display: false
        )

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
        guard orderPanelFront(panel) else {
            // The panel never made it on screen. Tear back down to the hidden
            // steady state (as hide() would) so the next toggle starts from a
            // fresh panel instead of finding this one orphaned behind
            // isVisible == false.
            hostingView?.removeFromSuperview()
            hostingView = nil
            self.panel = nil
            previousFrontmostApp = nil
            return
        }
        // Apply the current blur radius (0 = no blur) for this panel session.
        setWindowBackgroundBlur(panel, radius: Preferences.shared.windowBlurRadius)
        if let focusedID = splitState.focusedPaneID {
            FocusRestoration.restoreFocus(to: focusedID, in: splitState.splitRoot, window: panel)
        }
        isVisible = true
        // The grab handle moves the panel through the window server
        // (`performDrag(with:)`), which gives us no callback of its own — so
        // persist the position from AppKit's move notification instead.
        // Registered only after a successful order-front (the setFrame above
        // happened before this line, so initial placement never records
        // itself); hide() removes it with the panel.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(panelDidMove(_:)),
            name: NSWindow.didMoveNotification,
            object: panel
        )
    }

    @objc
    private func panelDidMove(_ notification: Notification) {
        guard isVisible,
              let panel,
              (notification.object as? NSWindow) === panel,
              Preferences.shared.quickTerminalDraggingEnabled,
              let screen = panel.screen ?? NSScreen.main
        else { return }
        Preferences.shared.quickTerminalPosition = QuickTerminalPlacement.position(
            of: panel.frame,
            in: screen.visibleFrame
        )
    }

    /// Refocus a pane after a close — retries briefly to wait for the new view.
    func refocusPane(_ paneID: UUID) {
        guard let panel, isVisible else { return }
        FocusRestoration.restoreFocus(to: paneID, in: splitState.splitRoot, window: panel)
    }

    private func hide() {
        if let panel {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: panel)
        }
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
        tab = TerminalTab(
            projectPath: NSHomeDirectory(),
            projectID: QuickTerminalService.ephemeralProjectID,
            sessionSlug: ZmxSessionName.quickTerminalSlug
        )
    }

    func focusPane(_ paneID: UUID) {
        tab.focusPane(paneID)
    }

    func setAdaptiveBackgroundColor(_ color: CGColor?, paneID: UUID) {
        guard let pane = tab.splitRoot.findPane(id: paneID),
              pane.adaptiveBackgroundColor != color
        else { return }
        pane.adaptiveBackgroundColor = color
    }

    func requestClosePane(_ paneID: UUID) {
        let needs = tab.splitRoot.findPane(id: paneID)?.needsConfirmClose ?? false
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
        if let panel = QuickTerminalService.shared.panelRef, orderPanelFront(panel) {
            // Tearing down the modal alert is a key/window transition — the
            // race FocusRestoration exists for. A bare makeFirstResponder here
            // can beat the panel regaining key status.
            if let focusedID = focusedPaneID {
                FocusRestoration.restoreFocus(to: focusedID, in: tab.splitRoot, window: panel)
            }
        }
        DispatchQueue.main.async {
            QuickTerminalService.shared.suppressAutoHide = false
        }
    }

    func split(paneID: UUID, direction: SplitDirection) {
        tab.split(paneID: paneID, direction: direction)
    }

    func autoSplit(paneID: UUID) {
        tab.autoSplit(paneID: paneID)
    }

    func resize(_ direction: PaneFocusDirection, delta: CGFloat = 0.03) {
        tab.resize(direction, delta: delta)
    }

    func closePane(_ paneID: UUID) {
        // Quick-terminal panes are ephemeral: closing one is permanent, so its
        // zmx session dies with it (transient hide/show never reaches here).
        tab.splitRoot.findPane(id: paneID)?.killPersistentSession(using: .live)
        switch tab.removePane(paneID) {
        case .onlyPaneLeft:
            // Replace the whole tab with a fresh one — the quick terminal should
            // always have at least one pane, but we fully reset so the prior
            // pane's surface is torn down (removePane already destroyed it).
            tab = TerminalTab(
                projectPath: NSHomeDirectory(),
                projectID: QuickTerminalService.ephemeralProjectID,
                sessionSlug: ZmxSessionName.quickTerminalSlug
            )
        case .removed,
             .notFound:
            break
        }
        if let newID = focusedPaneID {
            QuickTerminalService.shared.refocusPane(newID)
        }
    }
}

// MARK: - Placement

/// Pure frame math for showing the panel, kept out of the service so the
/// centering / restore / clamping rules are unit-testable.
enum QuickTerminalPlacement {
    /// The least of the panel that must stay on screen when restoring a
    /// dragged position: enough of the grab strip to catch and drag it back.
    static let minVisible: CGFloat = 60

    /// The panel frame for a show. Size comes from the screen-fraction
    /// preferences; the origin is centered unless a dragged `position` is
    /// given, in which case each axis restores the origin's stored place
    /// within the screen's spare room — faithfully, including a panel the
    /// user tucked partly off a screen edge. The restore clamps only as far
    /// as keeping `minVisible` points reachable per axis, with the top edge
    /// (where the grab handle lives) never above the visible frame — so a
    /// stale position from a different screen can nudge the panel back but
    /// never strand it where it can't be grabbed.
    static func frame(
        visibleFrame: NSRect,
        widthFraction: Double,
        heightFraction: Double,
        position: CGPoint?
    ) -> NSRect {
        let width = visibleFrame.width * widthFraction
        let height = visibleFrame.height * heightFraction
        let spareX = max(0, visibleFrame.width - width)
        let spareY = max(0, visibleFrame.height - height)
        guard let position else {
            return NSRect(
                x: visibleFrame.minX + spareX / 2,
                y: visibleFrame.minY + spareY / 2,
                width: width,
                height: height
            )
        }
        let x = visibleFrame.minX + spareX * position.x
        let y = visibleFrame.minY + spareY * position.y
        return NSRect(
            x: min(max(x, visibleFrame.minX + minVisible - width), visibleFrame.maxX - minVisible),
            y: min(max(y, visibleFrame.minY + minVisible - height), visibleFrame.maxY - height),
            width: width,
            height: height
        )
    }

    /// Inverse of `frame(visibleFrame:...)`: the per-axis fractions to persist
    /// for a panel the user just moved. Deliberately unclamped — a value
    /// beyond 0…1 means the panel overhangs a screen edge, and that placement
    /// is the user's to keep. An axis with no spare room (panel as large as
    /// the screen) reads as centered.
    static func position(of frame: NSRect, in visibleFrame: NSRect) -> CGPoint {
        let spareX = visibleFrame.width - frame.width
        let spareY = visibleFrame.height - frame.height
        return CGPoint(
            x: spareX > 0 ? (frame.minX - visibleFrame.minX) / spareX : 0.5,
            y: spareY > 0 ? (frame.minY - visibleFrame.minY) / spareY : 0.5
        )
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
    /// The pane currently dragged by its grab handle (`DraggingPaneKey`), so
    /// the dragged pane's own leaf drops its target.
    @State
    private var draggedPaneID: UUID?
    /// The live drop resolution the per-leaf pane targets report into; the
    /// workspace-level overlay renders its preview.
    @State
    private var dropResolution: TabDropResolution?

    var body: some View {
        let renderedNode: SplitNode = {
            if let zoomID = state.tab.zoomedPaneID, let pane = state.splitRoot.findPane(id: zoomID) {
                return .pane(pane)
            }
            return state.splitRoot
        }()
        VStack(spacing: 0) {
            if Preferences.shared.quickTerminalDraggingEnabled {
                QuickTerminalDragHandle()
            }
            splitTree(renderedNode)
        }
        .background(MactermTheme.bgWithOpacity)
        .onPreferenceChange(DraggingPaneKey.self) { value in
            MainActor.assumeIsolated {
                draggedPaneID = value
                if value == nil { dropResolution = nil }
            }
        }
    }

    private func splitTree(_ renderedNode: SplitNode) -> some View {
        SplitTreeView(
            node: renderedNode,
            focusedPaneID: state.focusedPaneID,
            zoomedPaneID: state.tab.zoomedPaneID,
            isActiveProject: true,
            projectID: QuickTerminalService.ephemeralProjectID,
            onFocusPane: { state.focusPane($0) },
            onSplit: { paneID, dir in state.split(paneID: paneID, direction: dir) },
            onClosePane: { state.closePane($0) },
            onCommandFinished: { paneID in
                guard QuickTerminalService.shared.panelRef?.isKeyWindow == true,
                      state.focusedPaneID == paneID,
                      let pane = state.tab.splitRoot.findPane(id: paneID)
                else { return }
                pane.acknowledgeCommandCompletion()
            },
            onAdaptiveBackgroundChange: { paneID, color in
                state.setAdaptiveBackgroundColor(color, paneID: paneID)
            },
            onToggleZoom: { state.tab.toggleZoom(paneID: $0) },
            paneDrop: PaneDropContext(
                root: renderedNode,
                resolution: $dropResolution,
                draggedPaneID: draggedPaneID,
                onMovePane: { paneID, target in
                    state.tab.movePane(paneID, to: target)
                }
            )
        )
        .id(renderedNode.id)
        // Grab-handle drags share the workspace drop grammar (whole-edge,
        // divider, local). The context carries no tab handler: the quick
        // terminal's ephemeral world doesn't adopt workspace tabs.
        .overlay {
            WorkspaceDropPreview(resolution: dropResolution)
        }
        .overlay(alignment: .topTrailing) {
            if let zoomID = state.tab.zoomedPaneID {
                ZoomIndicator(onExit: { state.tab.toggleZoom(paneID: zoomID) })
                    .padding(8)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Drag handle

/// The grab strip across the top of the panel when moving is enabled: a full-
/// width drag target (generous on purpose — a precision target is how the
/// split divider earned its grab band) with a centered capsule grabber as the
/// visual affordance, the shape macOS itself uses for grab handles. The strip
/// sits in its own layout row above the split tree, so unlike views layered
/// over a pane it owns no pane's events and forwards nothing.
private struct QuickTerminalDragHandle: View {
    var body: some View {
        WindowDragArea()
            .frame(maxWidth: .infinity)
            .frame(height: 14)
            .overlay {
                Capsule()
                    .fill(MactermTheme.fgDim)
                    .frame(width: 36, height: 5)
                    .allowsHitTesting(false)
            }
    }
}

/// AppKit-backed drag area: the drag is the window server's own
/// (`performDrag(with:)`), so it behaves exactly like a titlebar drag —
/// live window movement, screen-edge handling, multi-display — with none
/// of it reimplemented in a SwiftUI gesture.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context _: Context) -> DragAreaView {
        DragAreaView()
    }

    func updateNSView(_: DragAreaView, context _: Context) {}

    final class DragAreaView: NSView {
        /// Let the first click both key the panel and start the drag,
        /// matching how a real titlebar behaves on an inactive window.
        override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}
