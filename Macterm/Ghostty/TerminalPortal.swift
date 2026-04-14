import AppKit

/// Manages terminal views in a separate AppKit layer above SwiftUI.
///
/// Terminal views are never children of the SwiftUI view hierarchy. Instead,
/// SwiftUI renders invisible placeholder views that report their geometry.
/// The portal positions real terminal views to match those placeholders.
@MainActor
final class TerminalPortal {
    /// Per-window portal hosts, keyed by window identity.
    private static var hosts: [ObjectIdentifier: TerminalPortalHost] = [:]

    /// Get or create the portal host for a given window.
    static func host(for window: NSWindow) -> TerminalPortalHost {
        let key = ObjectIdentifier(window)
        if let existing = hosts[key] { return existing }
        let host = TerminalPortalHost(window: window)
        hosts[key] = host
        return host
    }

    static func removeHost(for window: NSWindow) {
        let key = ObjectIdentifier(window)
        hosts.removeValue(forKey: key)
    }
}

/// An NSView overlay installed in a window that owns all terminal views.
/// Terminal views are subviews of this host, positioned to match SwiftUI placeholders.
@MainActor
final class TerminalPortalHost {
    let overlayView: TerminalOverlayView
    private weak var window: NSWindow?
    private var entries: [UUID: Entry] = [:]

    struct Entry {
        let terminalView: GhosttyTerminalNSView
        weak var anchor: NSView?
        var isVisible: Bool
    }

    init(window: NSWindow) {
        self.window = window
        overlayView = TerminalOverlayView(frame: window.contentView?.bounds ?? .zero)
        overlayView.autoresizingMask = [.width, .height]
    }

    /// Install the overlay into the window's content view.
    func install() {
        guard let contentView = window?.contentView else { return }
        if overlayView.superview !== contentView {
            contentView.addSubview(overlayView, positioned: .above, relativeTo: nil)
            overlayView.frame = contentView.bounds
        }
    }

    /// Register or update a terminal view for a pane, anchored to a placeholder view.
    func bind(paneID: UUID, terminalView: GhosttyTerminalNSView, anchor: NSView, visible: Bool) {
        if terminalView.superview !== overlayView {
            overlayView.addSubview(terminalView)
        }
        entries[paneID] = Entry(terminalView: terminalView, anchor: anchor, isVisible: visible)
        terminalView.isHidden = !visible
        layoutEntry(paneID)
    }

    /// Update visibility for a pane (e.g., tab switch).
    func setVisible(_ visible: Bool, for paneID: UUID) {
        guard var entry = entries[paneID] else { return }
        entry.isVisible = visible
        entries[paneID] = entry
        entry.terminalView.isHidden = !visible
        if visible { layoutEntry(paneID) }
    }

    /// Remove a terminal view from the portal (pane closed).
    func unbind(paneID: UUID) {
        guard let entry = entries.removeValue(forKey: paneID) else { return }
        entry.terminalView.removeFromSuperview()
    }

    /// Reposition all visible terminal views to match their anchors.
    func layoutAll() {
        for paneID in entries.keys {
            layoutEntry(paneID)
        }
    }

    /// Reposition a single terminal view to match its anchor.
    func layoutEntry(_ paneID: UUID) {
        guard let entry = entries[paneID],
              let anchor = entry.anchor,
              anchor.window != nil
        else { return }

        let anchorFrame = overlayView.convert(anchor.bounds, from: anchor)
        if entry.terminalView.frame != anchorFrame {
            entry.terminalView.frame = anchorFrame
        }
    }
}

/// A transparent NSView that hosts all terminal views.
/// Passes hit testing through to terminal subviews.
final class TerminalOverlayView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only hit-test visible terminal subviews, pass through empty areas.
        // hitTest expects the point in the receiver's superview coordinates,
        // so we pass `point` (which is in our coordinate system) directly
        // to subviews since we are their superview.
        for sub in subviews.reversed() where !sub.isHidden {
            if let hit = sub.hitTest(point) { return hit }
        }
        return nil
    }
}
