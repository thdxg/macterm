import AppKit
import Carbon
import SwiftUI

@MainActor
final class QuickTerminalService: NSObject {
    static let shared = QuickTerminalService()

    private var panel: QuickTerminalPanel?
    private var hostingView: NSHostingView<QuickTerminalView>?
    private(set) var isVisible = false
    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonEventHandler: EventHandlerRef?
    let splitState = QuickTerminalSplitState()
    let viewCache = TerminalViewCache()
    private let enabledKey = "macterm.quickTerminal.enabled"

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    override private init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(toggle), name: .toggleQuickTerminal, object: nil)
        registerHotKey()
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
        let wFrac = max(0.2, min(1.0, UserDefaults.standard.double(forKey: "macterm.quickTerminal.width").nonZero ?? 0.6))
        let hFrac = max(0.2, min(1.0, UserDefaults.standard.double(forKey: "macterm.quickTerminal.height").nonZero ?? 0.5))
        let w = sf.width * wFrac, h = sf.height * hFrac
        panel.setFrame(NSRect(x: sf.minX + (sf.width - w) / 2, y: sf.minY + (sf.height - h) / 2, width: w, height: h), display: false)

        let view = QuickTerminalView(state: splitState, viewCache: viewCache)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)
        hostingView = hosting

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let focusedID = self.splitState.focusedPaneID {
                self.hostingView?.window?.makeFirstResponder(self.viewCache.existingView(for: focusedID))
            }
        }
        isVisible = true
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

    init() {
        let pane = Pane(projectPath: NSHomeDirectory())
        splitRoot = .pane(pane)
        focusedPaneID = pane.id
    }

    func split(paneID: UUID, direction: SplitDirection) {
        let (newRoot, newID) = splitRoot.splitting(
            paneID: paneID, direction: direction, position: .second, projectPath: NSHomeDirectory()
        )
        splitRoot = newRoot
        if let newID { focusedPaneID = newID }
    }

    func closePane(_ paneID: UUID, viewCache: TerminalViewCache) {
        guard splitRoot.findPane(id: paneID) != nil else { return }
        viewCache.remove(for: paneID)
        let panes = splitRoot.allPanes()
        if panes.count <= 1 {
            // Last pane — reset to a fresh pane instead of closing
            let pane = Pane(projectPath: NSHomeDirectory())
            splitRoot = .pane(pane)
            focusedPaneID = pane.id
        } else if let newRoot = splitRoot.removing(paneID: paneID) {
            splitRoot = newRoot
            if focusedPaneID == paneID { focusedPaneID = newRoot.allPanes().first?.id }
        }
    }
}

// MARK: - Panel

final class QuickTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        if QuickTerminalService.shared.isVisible {
            QuickTerminalService.shared.toggle()
        }
    }
}

// MARK: - Views

private struct QuickTerminalView: View {
    @Bindable var state: QuickTerminalSplitState
    let viewCache: TerminalViewCache

    var body: some View {
        SplitTreeView(
            node: state.splitRoot,
            focusedPaneID: state.focusedPaneID,
            isActiveProject: true,
            projectID: UUID(),
            viewCache: viewCache,
            onFocusPane: { state.focusedPaneID = $0 },
            onSplit: { paneID, dir in state.split(paneID: paneID, direction: dir) },
            onClosePane: { state.closePane($0, viewCache: viewCache) }
        )
        .background(Color(nsColor: GhosttyApp.shared.backgroundColor))
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
