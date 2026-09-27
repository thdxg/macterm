import AppKit
import os
import SwiftUI

private let logger = Logger(subsystem: appBundleID, category: "DesktopWidgetWindows")

/// Draws `AppState.desktopWidgets` on the desktop: one borderless panel per
/// widget, just above the desktop icons and below every ordinary window —
/// the layer the system's own widgets live on.
///
/// Why a window of our own rather than WidgetKit: a WidgetKit widget is an
/// archived SwiftUI snapshot rendered by another process, with no live view,
/// no text input and a refresh budget measured in minutes, so it cannot host
/// a terminal. The panel borrows the system widgets' look instead
/// (`DesktopWidgetMetrics`, `DesktopWidgetGrid`) and their manners: it stays
/// on the desktop through Mission Control and Show Desktop, is on every
/// Space, and never comes forward over the windows the user is working in.
@MainActor
final class DesktopWidgetWindows: DesktopWidgetPresenting {
    static let shared = DesktopWidgetWindows()

    private weak var appState: AppState?
    private var panels: [UUID: DesktopWidgetPanel] = [:]

    private init() {
        _ = NotificationCenter.default.addObserver(
            forName: .mactermConfigDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reapplyAppearance() }
        }
    }

    func attach(appState: AppState) {
        self.appState = appState
        appState.attachDesktopWidgetPresenter(self)
    }

    func sync(_ widgets: [DesktopWidget], editing: UUID?) {
        let live = Set(widgets.map(\.id))
        for (id, panel) in panels where !live.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
        }
        for widget in widgets {
            if let panel = panels[widget.id] {
                panel.apply(widget, isEditing: widget.id == editing)
            } else if let appState {
                let panel = DesktopWidgetPanel(widget: widget, appState: appState)
                panels[widget.id] = panel
                panel.orderFront(nil)
                WindowAppearance.syncDesktopWidget(panel)
                panel.apply(widget, isEditing: widget.id == editing)
            }
        }
    }

    private func reapplyAppearance() {
        for panel in panels.values {
            WindowAppearance.syncDesktopWidget(panel)
        }
    }
}

// MARK: - Panel

/// One widget's window. Locked (the default) it behaves like a system
/// widget: it can't become key and a shield covers it, so a click, a
/// selection drag or a wheel never reaches the terminal — but a drag
/// anywhere on it moves it. Being edited, it is a live terminal that can
/// also be dragged by its margin and resized by its edges, and it looks it:
/// the accent outline and a Done button.
final class DesktopWidgetPanel: NSPanel {
    /// One above the Finder's desktop icons — below every ordinary window,
    /// which is where the system draws its desktop widgets.
    static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)

    let widgetID: UUID
    private weak var appState: AppState?
    private let widgetContent: DesktopWidgetContentView
    private(set) var isEditing = false

    init(widget: DesktopWidget, appState: AppState) {
        widgetID = widget.id
        self.appState = appState
        widgetContent = DesktopWidgetContentView(widget: widget)
        super.init(contentRect: widget.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Desktop Widget"
        level = Self.desktopLevel
        // On the desktop of every Space, left in place by Mission Control and
        // Show Desktop, and out of the ⌘` window cycle — a widget is part of
        // the desktop, not a window the user switches between.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        minSize = DesktopWidgetGrid.dimensions(of: DesktopWidgetSpan(columns: 1, rows: 1))
        contentView = widgetContent
        widgetContent.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        widgetContent.onShellExit = { [weak appState, id = widget.id] in
            appState?.desktopWidgetShellExited(id: id)
        }
        widgetContent.onDragEnded = { [weak self] in self?.settle() }
        widgetContent.onDone = { [weak appState] in appState?.endEditingDesktopWidget() }
    }

    /// Keyboard input goes to the widget being edited and nowhere else.
    override var canBecomeKey: Bool { isEditing }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        // A non-activating panel takes keys while another app is frontmost,
        // so a chord typed here that opens a window of ours (⌘N, ⌘,) needs
        // the app activated for it — the quick terminal's handoff, shared.
        QuickTerminalService.shared.panelDidResignKey()
    }

    func apply(_ widget: DesktopWidget, isEditing editing: Bool) {
        if frame != widget.frame, !widgetContent.isResizing {
            // Animated, like a system widget settling into its grid cell.
            setFrame(widget.frame, display: true, animate: isVisible)
            invalidateShadow()
        }
        guard isEditing != editing else { return }
        isEditing = editing
        widgetContent.isEditing = editing
        if editing {
            // No shadow while editing: a KEY window's shadow and rim are
            // drawn from the window's rectangle, not its alpha, so the
            // edited widget grew a dark square behind its rounded corners
            // (measured: gone with the shadow off, unmoved by the style
            // mask or `invalidateShadow`). The accent outline carries the
            // edit state instead.
            hasShadow = false
            makeKeyAndOrderFront(nil)
            if let paneID = widget.pane?.id {
                FocusRestoration.restoreFocus(to: paneID, in: widget.tab.splitRoot, window: self)
            }
        } else {
            hasShadow = true
            invalidateShadow()
            if isKeyWindow {
                // `canBecomeKey` only gates the NEXT key change, so drop key
                // status now; ordering out and back in does it without
                // activating anything.
                orderOut(nil)
                orderFront(nil)
            }
        }
    }

    /// Hand the frame the user left the widget at to the grid.
    private func settle() {
        appState?.settleDesktopWidget(id: widgetID, frame: frame)
    }

    // MARK: Menu

    /// The system widgets' own right-click menu, as far as it applies: the
    /// edit toggle, the size families, then removal.
    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let appState, let widget = appState.desktopWidget(id: widgetID) else { return menu }
        if isEditing {
            menu.addItem(item("Done Editing", #selector(finishEditingFromMenu)))
        } else {
            let edit = item("Edit Widget", #selector(startEditingFromMenu))
            // One widget at a time: the one being edited has to be locked
            // before another can be unlocked.
            edit.isEnabled = appState.canEditDesktopWidget(id: widgetID)
            if !edit.isEnabled { edit.toolTip = "Finish editing the other widget first." }
            menu.addItem(edit)
        }
        menu.addItem(.separator())
        for size in DesktopWidgetSize.allCases {
            let sizeItem = item(size.title, #selector(chooseSize(_:)))
            sizeItem.representedObject = size.rawValue
            sizeItem.state = widget.span == size.span ? .on : .off
            menu.addItem(sizeItem)
        }
        menu.addItem(.separator())
        menu.addItem(item("Remove Widget", #selector(removeWidget)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc
    private func startEditingFromMenu() {
        appState?.beginEditingDesktopWidget(id: widgetID)
    }

    @objc
    private func finishEditingFromMenu() {
        appState?.endEditingDesktopWidget()
    }

    @objc
    private func chooseSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = DesktopWidgetSize(rawValue: raw) else { return }
        appState?.setDesktopWidgetSpan(size.span, id: widgetID)
    }

    @objc
    private func removeWidget() {
        guard let appState else { return }
        DesktopWidgetRemoval.confirmAndRemove(widgetID, in: appState)
    }
}

/// Removing a widget ends its shell, so a running program gets the same
/// confirmation a busy tab does. Shared by the widget's menu and Settings.
@MainActor
enum DesktopWidgetRemoval {
    static func confirmAndRemove(_ id: UUID, in appState: AppState) {
        if appState.desktopWidgetNeedsConfirmRemove(id: id) {
            let alert = NSAlert()
            alert.messageText = "Remove widget?"
            alert.informativeText = "A process is still running in this widget. Remove it anyway?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            // A widget's menu is used while another app is in front — widgets
            // never activate Macterm — and a modal alert in an inactive app
            // never comes forward: it sat unseen behind the frontmost app,
            // blocking, and "Remove Widget" looked like it did nothing. So the
            // app is activated for the alert, and the app that was in front
            // gets the focus back once it is answered.
            let previous = NSWorkspace.shared.frontmostApplication
            let wasActive = NSApp.isActive
            if !wasActive { appState.appDelegate?.activateWithoutReopen() }
            // And lifted to the floating level: the alert came up at the
            // normal level (measured), so if the activation is refused it
            // would still open behind the frontmost app's windows.
            alert.layout()
            alert.window.level = .floating
            let response = alert.runModal()
            if !wasActive, let previous, previous.bundleIdentifier != Bundle.main.bundleIdentifier {
                previous.activate()
            }
            guard response == .alertFirstButtonReturn else { return }
        }
        logger.info("removing desktop widget \(id.uuidString, privacy: .public)")
        appState.removeDesktopWidget(id: id)
    }
}

// MARK: - Content

/// The widget's rounded body. The terminal sits inset by the content margin;
/// the margin is the widget's own surface, where a drag moves the widget.
/// Locked, a shield covers the terminal too and hands it every press, so a
/// drag anywhere moves the widget and a right-click anywhere opens its menu,
/// as on a system widget; while editing, the terminal keeps its own drags
/// (selection) and right-clicks, and only the margin moves the widget.
///
/// Mouse handling is AppKit's because the terminal's NSView wins hit testing
/// over any SwiftUI gesture near it.
final class DesktopWidgetContentView: NSView {
    var menuProvider: () -> NSMenu = { NSMenu() }
    var onShellExit: () -> Void = {}
    var onDragEnded: () -> Void = {}
    var onDone: () -> Void = {}
    var isEditing = false {
        didSet { applyEditing() }
    }

    private let shield = DesktopWidgetShieldView()
    private let viewState = DesktopWidgetViewState()
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    /// Polls for the release that ends a window-server drag — the drag runs
    /// out of process, so no mouseUp ever reaches this view.
    private var dragReleaseTimer: Timer?
    private var trackingArea: NSTrackingArea?
    /// Mid edge-resize — the model's frame must not be pushed back onto the
    /// window until the resize has settled.
    private(set) var isResizing = false

    init(widget: DesktopWidget) {
        super.init(frame: CGRect(origin: .zero, size: widget.frame.size))
        wantsLayer = true
        // Clip everything, the terminal's Metal layer included, to the
        // widget's continuous corner.
        layer?.cornerRadius = DesktopWidgetMetrics.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: DesktopWidgetTerminalView(
            widget: widget,
            state: viewState,
            onShellExit: { [weak self] in self?.onShellExit() }
        ))
        let margin = DesktopWidgetMetrics.contentMargin
        hosting.frame = bounds.insetBy(dx: margin, dy: margin)
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)

        shield.frame = bounds
        shield.autoresizingMask = [.width, .height]
        shield.owner = self
        addSubview(shield)

        doneButton.bezelStyle = .push
        doneButton.controlSize = .small
        doneButton.target = self
        doneButton.action = #selector(done)
        doneButton.sizeToFit()
        doneButton.autoresizingMask = [.minXMargin, .maxYMargin]
        doneButton.frame.origin = CGPoint(
            x: bounds.maxX - doneButton.frame.width - margin,
            y: margin
        )
        addSubview(doneButton)
        applyEditing()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Being edited has to be unmistakable: the accent outline, the Done
    /// button, and the shield out of the terminal's way.
    private func applyEditing() {
        viewState.isEditing = isEditing
        shield.isHidden = isEditing
        doneButton.isHidden = !isEditing
        layer?.borderWidth = isEditing ? 3 : 0
        layer?.borderColor = MactermTheme.nsAccent.cgColor
    }

    @objc
    private func done() {
        onDone()
    }

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    /// How far the pointer travels before a press becomes a drag. A system
    /// widget stays put under a click; handing the drag over on mouse-down
    /// moved a widget by the few points a click jitters.
    private static let dragThreshold: CGFloat = 4

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let edges = resizeEdges(for: event)
        if !edges.isEmpty {
            resize(window, from: edges)
            return
        }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let travelled = hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y)
            guard travelled >= Self.dragThreshold else { continue }
            // The window server's own drag, so it moves like a titlebar drag
            // — live, across displays — with none of it reimplemented. It
            // returns at once; the release is polled for, then the grid
            // takes the frame.
            window.performDrag(with: event)
            watchForDragRelease()
            return
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(menuProvider(), with: event, for: self)
    }

    // MARK: Resize

    /// The widget's own edge resize, not AppKit's: a borderless window's
    /// resize area is a sliver, and most of a titled window's lies outside
    /// the frame in its shadow — which an edited widget doesn't have — so the
    /// resize cursor never appeared on hover. The outer band of the margin is
    /// the handle instead (`DesktopWidgetResize`), live, and the grid takes
    /// the frame on release.
    private func resize(_ window: NSWindow, from edges: DesktopWidgetResize.Edges) {
        isResizing = true
        let startFrame = window.frame
        let startMouse = NSEvent.mouseLocation
        DesktopWidgetResize.cursor(for: edges).set()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let mouse = NSEvent.mouseLocation
            window.setFrame(
                DesktopWidgetResize.frame(
                    from: startFrame,
                    edges: edges,
                    by: CGSize(width: mouse.x - startMouse.x, height: mouse.y - startMouse.y),
                    minSize: window.minSize
                ),
                display: true
            )
            if next.type == .leftMouseUp { break }
        }
        isResizing = false
        onDragEnded()
    }

    private func resizeEdges(for event: NSEvent) -> DesktopWidgetResize.Edges {
        guard isEditing else { return [] }
        return DesktopWidgetResize.edges(at: convert(event.locationInWindow, from: nil), in: bounds)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.activeAlways`: the widget is edited while another app is in
        // front (typing into it never activates Macterm).
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func mouseExited(with _: NSEvent) {
        guard !isResizing else { return }
        NSCursor.arrow.set()
    }

    /// The resize cursor over the band; the arrow over the rest of the
    /// margin. Over the terminal the terminal's own cursor stands.
    private func updateCursor(for event: NSEvent) {
        guard !isResizing else { return }
        let point = convert(event.locationInWindow, from: nil)
        let edges = resizeEdges(for: event)
        if !edges.isEmpty {
            DesktopWidgetResize.cursor(for: edges).set()
        } else if !bounds.insetBy(dx: DesktopWidgetMetrics.contentMargin, dy: DesktopWidgetMetrics.contentMargin).contains(point) {
            NSCursor.arrow.set()
        }
    }

    private func watchForDragRelease() {
        dragReleaseTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard NSEvent.pressedMouseButtons & 0x1 == 0 else { return }
            timer.invalidate()
            MainActor.assumeIsolated { self?.onDragEnded() }
        }
        dragReleaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// The edited widget's edge handles, as pure geometry.
enum DesktopWidgetResize {
    struct Edges: OptionSet, Hashable {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let top = Edges(rawValue: 1 << 2)
        static let bottom = Edges(rawValue: 1 << 3)
    }

    /// How deep the edge handle reaches in from the widget's edge. Inside the
    /// content margin (the terminal never loses a point to it), and leaving
    /// the margin's inner part for moving the widget.
    static let band: CGFloat = 7
    /// How far from a corner along its edges the handle resizes both ways —
    /// larger than the band, since a corner is the handle people reach for.
    static let corner: CGFloat = 20

    /// The edges a point grabs, in the widget's own (y-up) coordinates.
    static func edges(at point: CGPoint, in bounds: CGRect) -> Edges {
        let left = point.x - bounds.minX
        let right = bounds.maxX - point.x
        let bottom = point.y - bounds.minY
        let top = bounds.maxY - point.y
        guard bounds.contains(point), min(left, right, bottom, top) < band else { return [] }
        var edges: Edges = []
        if left < corner { edges.insert(.left) } else if right < corner { edges.insert(.right) }
        if bottom < corner { edges.insert(.bottom) } else if top < corner { edges.insert(.top) }
        return edges
    }

    /// The frame after dragging `edges` by `delta` (screen points, y up): the
    /// opposite edges stay put, and it never shrinks below `minSize`.
    static func frame(from start: CGRect, edges: Edges, by delta: CGSize, minSize: CGSize) -> CGRect {
        var frame = start
        if edges.contains(.right) {
            frame.size.width = max(minSize.width, start.width + delta.width)
        } else if edges.contains(.left) {
            frame.size.width = max(minSize.width, start.width - delta.width)
            frame.origin.x = start.maxX - frame.width
        }
        if edges.contains(.top) {
            frame.size.height = max(minSize.height, start.height + delta.height)
        } else if edges.contains(.bottom) {
            frame.size.height = max(minSize.height, start.height - delta.height)
            frame.origin.y = start.maxY - frame.height
        }
        return frame
    }

    /// The system's frame-resize cursor for a handle (macOS 15+), else the
    /// nearest older one.
    @MainActor
    static func cursor(for edges: Edges) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition = switch edges {
            case [.top, .left]: .topLeft
            case [.top, .right]: .topRight
            case [.bottom, .left]: .bottomLeft
            case [.bottom, .right]: .bottomRight
            case [.left]: .left
            case [.right]: .right
            case [.top]: .top
            default: .bottom
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        if edges == [.left] || edges == [.right] { return .resizeLeftRight }
        if edges == [.top] || edges == [.bottom] { return .resizeUpDown }
        return .crosshair
    }
}

/// Covers a locked widget: takes every mouse event over it so none reaches
/// the terminal — no click, no selection, no wheel (over mouse reporting or
/// the alternate screen's alternate scroll a wheel is input too) — and hands
/// the press and the right-click to the widget, which drags and opens its
/// menu with them.
private final class DesktopWidgetShieldView: NSView {
    weak var owner: DesktopWidgetContentView?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        owner?.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        owner?.rightMouseDown(with: event)
    }

    override func scrollWheel(with _: NSEvent) {}
    override func otherMouseDown(with _: NSEvent) {}
}

/// What the widget's SwiftUI content needs from its window.
@MainActor @Observable
private final class DesktopWidgetViewState {
    var isEditing = false
}

/// The widget's one pane, through the same split-tree view every terminal
/// uses. Splits are no-ops: a widget is one pane (`DesktopWidget`).
private struct DesktopWidgetTerminalView: View {
    let widget: DesktopWidget
    let state: DesktopWidgetViewState
    let onShellExit: () -> Void

    var body: some View {
        let tab = widget.tab
        SplitRootView(
            tabID: tab.id,
            root: tab.splitRoot,
            // Only the widget being edited has a focused pane. A widget's one
            // pane is always its tab's focused pane, and passing that through
            // unconditionally told every locked widget's surface it had focus
            // — a solid, blinking cursor in a terminal nobody can type into.
            focusedPaneID: state.isEditing ? tab.focusedPaneID : nil,
            zoomedPaneID: nil,
            isActiveProject: true,
            projectID: DesktopWidget.projectID,
            onFocusPane: { tab.focusPane($0) },
            onSplit: { _, _, _ in },
            onClosePane: { _ in onShellExit() },
            onCommandFinished: { paneID in
                guard let pane = tab.splitRoot.findPane(id: paneID),
                      pane.nsView?.window?.isKeyWindow == true
                else { return }
                pane.acknowledgeCommandCompletion()
            },
            onAdaptiveBackgroundChange: { paneID, color in
                guard let pane = tab.splitRoot.findPane(id: paneID), pane.adaptiveBackgroundColor != color else { return }
                pane.adaptiveBackgroundColor = color
            }
        )
    }
}
