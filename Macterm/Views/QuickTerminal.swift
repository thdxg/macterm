import AppKit
import Carbon
import SwiftUI

@MainActor
final class QuickTerminalService: NSObject {
    static let shared = QuickTerminalService()

    private(set) var panel: QuickTerminalPanel?
    var panelRef: QuickTerminalPanel? { panel }
    private var hostingView: NSHostingView<QuickTerminalView>?
    private(set) var isVisible = false
    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonEventHandler: EventHandlerRef?
    let splitState = QuickTerminalSplitState()
    var suppressAutoHide = false
    private var isEnabled: Bool {
        Preferences.shared.quickTerminalEnabled
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
        registerHotKey()
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

    // MARK: - Hot key

    private func registerHotKey() {
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
                DispatchQueue.main.async {
                    guard svc.isEnabled else {
                        if svc.isVisible { svc.hide() }
                        return
                    }
                    svc.toggle()
                }
            }
            return noErr
        }, 1, &spec, selfPtr, &carbonEventHandler)

        // Ctrl+` (key code 50)
        RegisterEventHotKey(50, UInt32(controlKey), hotKeyID, GetApplicationEventTarget(), 0, &carbonHotKeyRef)
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

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let focusedID = self.splitState.focusedPaneID,
               let pane = self.splitState.splitRoot.findPane(id: focusedID),
               let view = pane.nsView
            {
                view.window?.makeFirstResponder(view)
            }
        }
        isVisible = true
    }

    /// Refocus a pane after a close — retries briefly to wait for the new view.
    func refocusPane(_ paneID: UUID, attempt: Int = 0) {
        guard let panel, isVisible else { return }
        if let pane = splitState.splitRoot.findPane(id: paneID),
           let view = pane.nsView, view.window === panel
        {
            panel.makeFirstResponder(view)
            view.notifySurfaceFocused()
            return
        }
        guard attempt < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.refocusPane(paneID, attempt: attempt + 1)
        }
    }

    private func hide() {
        panel?.orderOut(nil)
        hostingView?.removeFromSuperview()
        hostingView = nil
        panel = nil
        isVisible = false
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

@MainActor @Observable
final class QuickTerminalSplitState {
    var splitRoot: SplitNode
    var focusedPaneID: UUID?
    var pendingClosePaneID: UUID?
    @ObservationIgnored
    var paneFocusHistory = RecencyStack<UUID>(limit: 20)

    init() {
        let pane = Pane(projectPath: NSHomeDirectory())
        splitRoot = .pane(pane)
        focusedPaneID = pane.id
    }

    /// Record a focus change, pushing the previous pane onto history.
    func focusPane(_ paneID: UUID) {
        guard paneID != focusedPaneID else { return }
        if let current = focusedPaneID { paneFocusHistory.push(current) }
        paneFocusHistory.remove(paneID)
        focusedPaneID = paneID
    }

    /// Pick the next focus target after a pane is removed.
    private func nextFocusAfterClose() -> UUID? {
        let valid = Set(splitRoot.allPanes().map(\.id))
        paneFocusHistory.prune(keeping: valid)
        if let recent = paneFocusHistory.popValid(in: valid) { return recent }
        return splitRoot.allPanes().first?.id
    }

    func requestClosePane(_ paneID: UUID) {
        let needs = splitRoot.findPane(id: paneID)?.nsView?.needsConfirmQuit() ?? false
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
               let view = splitRoot.findPane(id: focusedID)?.nsView
            {
                panel.makeFirstResponder(view)
            }
        }
        DispatchQueue.main.async {
            QuickTerminalService.shared.suppressAutoHide = false
        }
    }

    func split(paneID: UUID, direction: SplitDirection) {
        let pane = splitRoot.findPane(id: paneID)
        let livePwd = pane?.nsView?.currentPwd
        let sourcePath = livePwd ?? pane?.projectPath ?? NSHomeDirectory()
        let (newRoot, newID) = splitRoot.splitting(
            paneID: paneID, direction: direction, position: .second, projectPath: sourcePath
        )
        splitRoot = newRoot
        if let newID { focusPane(newID) }
        if Preferences.shared.autoTilingEnabled { splitRoot.rebalanced() }
    }

    func resize(_ direction: PaneFocusDirection, delta: CGFloat = 0.03) {
        guard let paneID = focusedPaneID else { return }
        splitRoot = splitRoot.resizing(paneID: paneID, direction: direction, delta: delta)
    }

    func closePane(_ paneID: UUID) {
        guard let pane = splitRoot.findPane(id: paneID) else { return }
        pane.destroySurface()
        let panes = splitRoot.allPanes()
        if panes.count <= 1 {
            let pane = Pane(projectPath: NSHomeDirectory())
            splitRoot = .pane(pane)
            focusedPaneID = pane.id
            paneFocusHistory.removeAll()
        } else if let newRoot = splitRoot.removing(paneID: paneID) {
            splitRoot = newRoot
            paneFocusHistory.remove(paneID)
            if focusedPaneID == paneID {
                focusedPaneID = nextFocusAfterClose()
            }
            if Preferences.shared.autoTilingEnabled { splitRoot.rebalanced() }
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
    static let projectID = UUID()
    @Bindable var state: QuickTerminalSplitState

    var body: some View {
        SplitTreeView(
            node: state.splitRoot,
            focusedPaneID: state.focusedPaneID,
            isActiveProject: true,
            projectID: Self.projectID,
            onFocusPane: { state.focusPane($0) },
            onSplit: { paneID, dir in state.split(paneID: paneID, direction: dir) },
            onClosePane: { state.closePane($0) }
        )
        .id(state.splitRoot.id)
        .background(Color(nsColor: GhosttyApp.shared.backgroundColor))
    }
}
