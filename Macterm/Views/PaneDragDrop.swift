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

/// The grab-handle drag as seen by its drop targets: the pane UUID
/// `PaneDragSource` writes as 16 raw bytes under `.mactermPaneID`.
///
/// Deliberately NOT `Transferable` itself: the drag lifts as an AppKit
/// `NSDraggingSession` (see `PaneDragSource`), never through `.draggable`, so
/// there is no export side to declare, and the two importers that do exist —
/// the sidebar's `SidebarDropItem` and `TabSlotDropItem` unions — decode these
/// bytes as one case among several. The workspace leaves read the pasteboard
/// directly instead (`fromDragPasteboard`), so every path decodes the same 16
/// bytes through `init?(payload:)`.
struct MovablePane {
    let paneID: UUID

    /// Decode the wire form: the pane UUID as 16 raw bytes. The one decoder
    /// every drop path shares, so the leaves' pasteboard read and the
    /// sidebar's `Transferable` import can't drift.
    init?(payload: Data) {
        guard payload.count == 16 else { return nil }
        self.init(paneID: payload.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) })
    }

    init(paneID: UUID) {
        self.paneID = paneID
    }

    /// The wire form of a pane's identity — what `PaneDragSource` puts on the
    /// drag pasteboard.
    static func payload(for paneID: UUID) -> Data {
        withUnsafeBytes(of: paneID.uuid) { Data($0) }
    }

    /// Decode the drag's payload synchronously off the drag pasteboard — the
    /// path the workspace leaves take, since a raw `DropDelegate` gets the
    /// session but not a decoded payload. The bytes are written eagerly at
    /// mouseDragged, so nil simply means "not a pane drag".
    static func fromDragPasteboard() -> MovablePane? {
        guard let data = NSPasteboard(name: .drag).pasteboardItems?
            .compactMap({ $0.data(forType: .mactermPaneID) })
            .first
        else { return nil }
        return MovablePane(payload: data)
    }
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
            pasteboardItem.setData(MovablePane.payload(for: pane.id), forType: .mactermPaneID)
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

// MARK: - Workspace drop target (#227)

/// Everything a leaf's drop target needs to resolve against the WHOLE
/// workspace: the rendered tree, the shared resolution/preview binding owned
/// by the workspace view, the pane currently being dragged, and the actions
/// to perform on release. Leaves only capture events; placement always goes
/// through `TabDropPlacer` in workspace space.
struct PaneDropContext {
    let root: SplitNode
    let resolution: Binding<TabDropResolution?>
    let draggedPaneID: UUID?
    /// The tab whose split tree this workspace is rendering. A sidebar drag
    /// of that tab over its own workspace could only self-merge — a no-op in
    /// `AppState.mergeTab` — so the leaves refuse it instead of previewing a
    /// split that won't happen. nil (the quick terminal) skips the check; it
    /// refuses tab payloads entirely anyway.
    var renderedTabID: UUID?
    let onMovePane: @MainActor (UUID, TabDropResolution.Target) -> Void
    /// nil (the quick terminal) refuses sidebar-tab payloads entirely.
    var onMergeTab: (@MainActor (MovableTab, TabDropResolution.Target) -> Void)?

    /// The payload types the leaf targets register for.
    var acceptedTypes: [UTType] {
        onMergeTab == nil ? [.mactermPaneID] : [.mactermPaneID, .mactermTab]
    }
}

/// Renders the shared drop preview over the whole workspace. Deliberately NOT
/// a drop target: SwiftUI routes a drag to the topmost target by geometry and
/// does not fall through on a type mismatch, so any full-area target layered
/// above the leaves would swallow every session the leaves should get. The
/// leaves (which tile the workspace exactly) own all drop handling — see
/// `LeafDropDelegate` — and report into `resolution`; this view only draws
/// the region the drop would occupy.
struct WorkspaceDropPreview: View {
    let resolution: TabDropResolution?

    var body: some View {
        GeometryReader { geo in
            if let resolution {
                RoundedRectangle(cornerRadius: 4)
                    .fill(MactermTheme.accent.opacity(0.3))
                    .frame(
                        width: resolution.preview.width * geo.size.width,
                        height: resolution.preview.height * geo.size.height
                    )
                    .offset(
                        x: resolution.preview.minX * geo.size.width,
                        y: resolution.preview.minY * geo.size.height
                    )
            }
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.12), value: resolution?.preview)
    }
}

/// Per-leaf drop capture for BOTH drags — a pane's grab handle and a sidebar
/// tab. Per leaf, not one whole-workspace target, for two reasons: AppKit
/// only fires dragging-entered on a transition INTO a destination, so a
/// whole-area target never hears about a pane drag that started inside it;
/// and SwiftUI's topmost-wins routing means a full-area target would shadow
/// everything beneath. Each leaf converts its local location into workspace
/// space via the pane's frame in the tree and resolves through the same
/// `TabDropPlacer` into the shared resolution, so the placement bands and
/// preview are identical for every drag. The dragged pane's own leaf carries
/// no target (a self-drop is meaningless and an invalid drop animates back).
struct LeafDropDelegate: DropDelegate {
    let context: PaneDropContext
    let paneID: UUID
    let viewSize: CGSize

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: context.acceptedTypes) && !isRenderedTabDrag()
    }

    func dropEntered(info: DropInfo) {
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // dropUpdated can fire after performDrop; without this guard it would
        // re-show the preview on a completed drop and leave it stuck.
        guard context.resolution.wrappedValue != nil else { return DropProposal(operation: .forbidden) }
        update(info)
        return DropProposal(operation: context.resolution.wrappedValue == nil ? .cancel : .move)
    }

    func dropExited(info _: DropInfo) {
        context.resolution.wrappedValue = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        update(info)
        guard let target = context.resolution.wrappedValue?.target else {
            context.resolution.wrappedValue = nil
            return false
        }
        context.resolution.wrappedValue = nil

        // A pane drag first: its payload is a UUID, usually readable
        // synchronously off the drag pasteboard (this drag never leaves the
        // app — sourceOperationMask is .move only within the application).
        if let movable = MovablePane.fromDragPasteboard() {
            let move = context.onMovePane
            MainActor.assumeIsolated { move(movable.paneID, target) }
            return true
        }
        guard let onMergeTab = context.onMergeTab else { return false }
        if let movable = MovableTab.fromDragPasteboard() {
            MainActor.assumeIsolated { onMergeTab(movable, target) }
            return true
        }
        // Fallback when the Transferable payload wasn't rendered onto the
        // pasteboard yet: the item provider's async loader. Locally-named
        // copy (not a `let x = x` shadow) so the @Sendable closure doesn't
        // capture non-Sendable self.
        guard let provider = info.itemProviders(for: [.mactermTab]).first else { return false }
        let merge = onMergeTab
        provider.loadDataRepresentation(forTypeIdentifier: UTType.mactermTab.identifier) { data, _ in
            guard let data, let movable = try? JSONDecoder().decode(MovableTab.self, from: data) else { return }
            Task { @MainActor in
                merge(movable, target)
            }
        }
        return true
    }

    /// True when the drag is the sidebar row of the tab this workspace is
    /// already rendering — the one tab payload whose drop could only
    /// self-merge, which `AppState.mergeTab` refuses. Falls open when the
    /// Transferable payload isn't on the drag pasteboard yet; the preview
    /// then shows and the drop lands on that same mergeTab guard (the same
    /// degradation the row-level merge delegate documents).
    private func isRenderedTabDrag() -> Bool {
        guard let renderedTabID = context.renderedTabID,
              let movable = MovableTab.fromDragPasteboard()
        else { return false }
        return movable.tabID == renderedTabID
    }

    private func update(_ info: DropInfo) {
        guard viewSize.width > 0, viewSize.height > 0, !isRenderedTabDrag() else {
            context.resolution.wrappedValue = nil
            return
        }
        let resolved: TabDropResolution? = MainActor.assumeIsolated {
            guard let frame = context.root.paneFrames()[paneID] else { return nil }
            let point = CGPoint(
                x: frame.minX + (info.location.x / viewSize.width) * frame.width,
                y: frame.minY + (info.location.y / viewSize.height) * frame.height
            )
            return TabDropPlacer.resolve(point: point, in: context.root)
        }
        // A target aimed at the dragged pane itself is meaningless; show
        // nothing rather than a lying preview.
        if let dragged = context.draggedPaneID {
            switch resolved?.target {
            case let .pane(id, _) where id == dragged,
                 let .divider(id, _) where id == dragged:
                context.resolution.wrappedValue = nil
                return
            default:
                break
            }
        }
        context.resolution.wrappedValue = resolved
    }
}

extension MovableTab {
    /// Decode the dragged tab's payload synchronously off the drag pasteboard.
    /// This drag never leaves the app, so the data is usually available
    /// without the item provider's background-queue round trip; returns nil
    /// when the Transferable hasn't rendered it yet.
    static func fromDragPasteboard() -> MovableTab? {
        guard let data = NSPasteboard(name: .drag).pasteboardItems?
            .compactMap({ $0.data(forType: NSPasteboard.PasteboardType(UTType.mactermTab.identifier)) })
            .first
        else { return nil }
        return try? JSONDecoder().decode(MovableTab.self, from: data)
    }
}
