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

    /// Get an existing portal host for a window, or nil if none.
    static func hostIfExists(for window: NSWindow) -> TerminalPortalHost? {
        hosts[ObjectIdentifier(window)]
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
    var isPaletteActive: Bool {
        get { overlayView.isPaletteActive }
        set {
            overlayView.isPaletteActive = newValue
            // Move the overlay below SwiftUI content so clicks naturally fall through
            // to the palette. When palette closes, put it back above.
            if let contentView = overlayView.superview {
                contentView.addSubview(
                    overlayView,
                    positioned: newValue ? .below : .above,
                    relativeTo: nil
                )
            }
        }
    }

    struct Entry {
        let terminalView: GhosttyTerminalNSView
        weak var anchor: NSView?
        var isVisible: Bool
        var searchBarHeight: CGFloat = 0
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

    /// Set how many points at the top of the anchor are reserved by the search bar.
    /// The terminal view frame is inset by this amount so the search bar can receive clicks.
    func setSearchBarHeight(_ height: CGFloat, for paneID: UUID) {
        guard var entry = entries[paneID] else { return }
        entry.searchBarHeight = height
        entries[paneID] = entry
        layoutEntry(paneID)
    }

    /// Remove a terminal view from the portal (pane closed).
    func unbind(paneID: UUID) {
        guard let entry = entries.removeValue(forKey: paneID) else { return }
        // Hide before removing to prevent Metal layer from flashing stale content.
        entry.terminalView.isHidden = true
        entry.terminalView.removeFromSuperview()
    }

    /// Hide all terminal views in the portal.
    func hideAll() {
        for (paneID, _) in entries {
            setVisible(false, for: paneID)
        }
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

        var anchorFrame = overlayView.convert(anchor.bounds, from: anchor)
        let barHeight = entry.searchBarHeight
        if barHeight > 0 {
            anchorFrame.origin.y += barHeight
            anchorFrame.size.height = max(0, anchorFrame.size.height - barHeight)
        }
        if entry.terminalView.frame != anchorFrame {
            entry.terminalView.frame = anchorFrame
        }
    }
}

/// A transparent NSView that hosts all terminal views.
/// Passes hit testing through to terminal subviews.
final class TerminalOverlayView: NSView {
    override var isFlipped: Bool { true }
    var isPaletteActive = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // When the command palette is open, pass all clicks through to SwiftUI.
        if isPaletteActive { return nil }
        // Convert the incoming point (in superview coordinates) to our own coordinate system.
        let localPoint = convert(point, from: superview)
        // Only hit-test visible terminal subviews, pass through empty areas.
        for sub in subviews.reversed() where !sub.isHidden {
            if sub.frame.contains(localPoint) {
                if let hit = sub.hitTest(localPoint) { return hit }
            }
        }
        return nil
    }
}
