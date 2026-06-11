import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Drag-and-drop pane reorganization, following Ghostty's pattern: each pane
// shows a small grab handle at its top center (revealed while the pointer is
// in the pane's top band). Dragging the handle starts an `NSDraggingSession`
// carrying the pane's UUID; every other pane is a drop target split into four
// triangular edge zones, highlighting the half where the dragged pane will
// land. The drop is handled by `TerminalTab.movePane` — the `Pane` object
// (and its live surface) is reused, only the tree is reshaped.

extension UTType {
    /// In-app drag payload identifying the pane being moved: its UUID bytes.
    static let mactermPaneID = UTType(exportedAs: "com.thdxg.macterm.pane-id")
}

extension NSPasteboard.PasteboardType {
    static let mactermPaneID = NSPasteboard.PasteboardType(UTType.mactermPaneID.identifier)
}

/// Propagates the ID of the pane currently being dragged (nil when idle) from
/// the grab handle up to its own leaf, so the source pane can disable its drop
/// target — a drop on itself is meaningless, and an invalid drop should
/// animate back to where it started.
struct DraggingPaneKey: PreferenceKey {
    static let defaultValue: UUID? = nil

    static func reduce(value: inout UUID?, nextValue: () -> UUID?) {
        value = nextValue() ?? value
    }
}

// MARK: - Grab handle

/// The grab handle overlay for one pane. Only the small pill itself is
/// hit-testable; the reveal band underneath passes all clicks through to the
/// terminal (see `PaneHoverSensor`).
struct PaneGrabHandle: View {
    private static let handleSize = CGSize(width: 80, height: 12)
    /// Reveal the handle while the pointer is in the top fraction of the pane.
    private static let hoverBandFactor: CGFloat = 0.2

    let pane: Pane

    @State private var inRevealBand = false
    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                PaneHoverSensor(isInside: $inRevealBand)
                    .frame(height: min(geo.size.height, max(Self.handleSize.height, geo.size.height * Self.hoverBandFactor)))
                    .frame(maxHeight: .infinity, alignment: .top)

                ZStack {
                    PaneDragSource(pane: pane, isDragging: $isDragging, isHovering: $isHovering)
                        .frame(width: Self.handleSize.width, height: Self.handleSize.height)

                    if inRevealBand || isHovering || isDragging {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MactermTheme.fg.opacity(isHovering || isDragging ? 0.8 : 0.35))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .preference(key: DraggingPaneKey.self, value: isDragging ? pane.id : nil)
    }
}

/// An invisible band that reports pointer presence without participating in
/// hit testing: `hitTest` returns nil so clicks reach the terminal underneath,
/// while the tracking area still delivers entered/exited events (tracking
/// areas bypass hit testing).
private struct PaneHoverSensor: NSViewRepresentable {
    @Binding var isInside: Bool

    func makeNSView(context _: Context) -> SensorView {
        let view = SensorView()
        view.onChange = { isInside = $0 }
        return view
    }

    func updateNSView(_ view: SensorView, context _: Context) {
        view.onChange = { isInside = $0 }
    }

    final class SensorView: NSView {
        var onChange: ((Bool) -> Void)?

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseEntered(with _: NSEvent) {
            onChange?(true)
        }

        override func mouseExited(with _: NSEvent) {
            onChange?(false)
        }
    }
}

// MARK: - Drag source

/// AppKit-backed drag source: starting the drag through an `NSDraggingSession`
/// (instead of SwiftUI's `.onDrag`) lets us consume the mouseDown so the grab
/// handle doesn't move the window, show open/closed-hand cursors, and use a
/// live snapshot of the pane as the drag image.
private struct PaneDragSource: NSViewRepresentable {
    let pane: Pane
    @Binding var isDragging: Bool
    @Binding var isHovering: Bool

    func makeNSView(context _: Context) -> DragSourceView {
        let view = DragSourceView()
        configure(view)
        return view
    }

    func updateNSView(_ view: DragSourceView, context _: Context) {
        configure(view)
    }

    private func configure(_ view: DragSourceView) {
        view.pane = pane
        view.onDragStateChanged = { dragging in
            withAnimation(.easeInOut(duration: 0.15)) { isDragging = dragging }
        }
        view.onHoverChanged = { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovering = hovering }
        }
    }

    final class DragSourceView: NSView, NSDraggingSource {
        /// Scale applied to the pane snapshot for the drag preview image.
        private static let previewScale: CGFloat = 0.2

        var pane: Pane?
        var onDragStateChanged: ((Bool) -> Void)?
        var onHoverChanged: ((Bool) -> Void)?

        /// True while a drag session is in flight; drives the cursor rect.
        private var isTracking = false

        override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
            true
        }

        override func mouseDown(with _: NSEvent) {
            // Consume the press so it can't fall through to the window's drag
            // region (which would move the window instead of the pane). The
            // drag itself starts in mouseDragged.
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: isTracking ? .closedHand : .openHand)
        }

        override func mouseEntered(with _: NSEvent) {
            onHoverChanged?(true)
        }

        override func mouseExited(with _: NSEvent) {
            onHoverChanged?(false)
        }

        override func mouseDragged(with event: NSEvent) {
            guard !isTracking, let pane else { return }

            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setData(
                withUnsafeBytes(of: pane.id.uuid) { Data($0) },
                forType: .mactermPaneID
            )
            let item = NSDraggingItem(pasteboardWriter: pasteboardItem)

            let image = dragPreviewImage(for: pane)
            // Center the image on the cursor, matching native macOS tab drags.
            let mouse = convert(event.locationInWindow, from: nil)
            item.setDraggingFrame(
                NSRect(
                    x: mouse.x - image.size.width / 2,
                    y: mouse.y - image.size.height / 2,
                    width: image.size.width,
                    height: image.size.height
                ),
                contents: image
            )

            onDragStateChanged?(true)
            beginDraggingSession(with: [item], event: event, source: self)
        }

        /// A scaled live snapshot of the pane's surface; falls back to a plain
        /// theme-colored card if the view can't render one.
        private func dragPreviewImage(for pane: Pane) -> NSImage {
            if let view = pane.nsView, !view.bounds.isEmpty,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            {
                view.cacheDisplay(in: view.bounds, to: rep)
                let snapshot = NSImage(size: view.bounds.size)
                snapshot.addRepresentation(rep)
                let size = NSSize(
                    width: snapshot.size.width * Self.previewScale,
                    height: snapshot.size.height * Self.previewScale
                )
                return NSImage(size: size, flipped: false) { rect in
                    snapshot.draw(in: rect, from: NSRect(origin: .zero, size: snapshot.size), operation: .copy, fraction: 1)
                    return true
                }
            }
            let bg = MactermTheme.nsBg
            return NSImage(size: NSSize(width: 160, height: 100), flipped: false) { rect in
                let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
                bg.setFill()
                path.fill()
                NSColor.separatorColor.setStroke()
                path.stroke()
                return true
            }
        }

        // MARK: NSDraggingSource

        nonisolated func draggingSession(
            _: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }

        nonisolated func draggingSession(_: NSDraggingSession, willBeginAt _: NSPoint) {
            MainActor.assumeIsolated {
                isTracking = true
                window?.invalidateCursorRects(for: self)
            }
        }

        nonisolated func draggingSession(_: NSDraggingSession, movedTo _: NSPoint) {
            MainActor.assumeIsolated { NSCursor.closedHand.set() }
        }

        nonisolated func draggingSession(_: NSDraggingSession, endedAt _: NSPoint, operation _: NSDragOperation) {
            MainActor.assumeIsolated {
                isTracking = false
                window?.invalidateCursorRects(for: self)
                onDragStateChanged?(false)
            }
        }
    }
}

// MARK: - Drop target

enum PaneDropState: Equatable {
    case idle
    case dropping(PaneDropZone)
}

/// Per-pane drop target. The zone follows the cursor; the actual move is
/// performed by `onMove(sourcePaneID, destinationPaneID, zone)`.
struct PaneDropDelegate: DropDelegate {
    @Binding var dropState: PaneDropState
    let viewSize: CGSize
    let destinationPaneID: UUID
    let onMove: @MainActor (UUID, UUID, PaneDropZone) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.mactermPaneID])
    }

    func dropEntered(info: DropInfo) {
        dropState = .dropping(.calculate(at: info.location, in: viewSize))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // dropUpdated can fire after performDrop; without this guard it would
        // re-show the zone highlight on a completed drop.
        guard case .dropping = dropState else { return DropProposal(operation: .forbidden) }
        dropState = .dropping(.calculate(at: info.location, in: viewSize))
        return DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        dropState = .idle
    }

    func performDrop(info: DropInfo) -> Bool {
        let zone = PaneDropZone.calculate(at: info.location, in: viewSize)
        dropState = .idle

        // This drag never leaves the app (sourceOperationMask is .move only
        // within the application), so the payload can be read synchronously
        // off the drag pasteboard instead of round-tripping through the
        // NSItemProvider's background-queue loader.
        guard let data = NSPasteboard(name: .drag).pasteboardItems?
            .compactMap({ $0.data(forType: .mactermPaneID) })
            .first, data.count == 16
        else { return false }
        let sourceID = data.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
        guard sourceID != destinationPaneID else { return false }

        MainActor.assumeIsolated {
            onMove(sourceID, destinationPaneID, zone)
        }
        return true
    }
}

extension PaneDropZone {
    /// The half of the destination pane the dragged pane would occupy.
    @MainActor
    func highlight(in size: CGSize) -> some View {
        Rectangle()
            .fill(MactermTheme.accent.opacity(0.3))
            .frame(
                width: splitDirection == .horizontal ? size.width / 2 : nil,
                height: splitDirection == .vertical ? size.height / 2 : nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private var alignment: Alignment {
        switch self {
        case .left: .leading
        case .right: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }
}
