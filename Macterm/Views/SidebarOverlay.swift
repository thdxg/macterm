import AppKit
import SwiftUI

/// The overlay peek is a separate visual surface, never a second split-view
/// column. Its inset exposes the terminal around a rounded Liquid Glass panel
/// while the sidebar content keeps the titlebar's safe area.
struct SidebarOverlayPanel: View {
    let width: CGFloat
    let chromeHidden: Bool
    let windowCornerRadius: CGFloat?
    let onResize: (CGFloat) -> Void
    let onResizeStateChanged: (Bool) -> Void

    private var cornerRadius: CGFloat {
        SidebarOverlayMetrics.cornerRadius(
            windowCornerRadius: windowCornerRadius,
            inset: SidebarOverlayMetrics.panelInset
        )
    }

    var body: some View {
        SidebarContent()
            .safeAreaPadding(.top, chromeHidden ? SidebarOverlayMetrics.panelInset : 0)
            .safeAreaPadding(.bottom, SidebarOverlayMetrics.panelInset)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background {
                SidebarOverlayBackground(cornerRadius: cornerRadius)
                    .padding(.vertical, SidebarOverlayMetrics.panelInset)
                    .ignoresSafeArea(.container, edges: .vertical)
            }
            .overlay(alignment: .trailing) {
                SidebarResizeBand(
                    widthAtDragStart: { width },
                    onResize: onResize,
                    onResizeStateChanged: onResizeStateChanged
                )
                .frame(width: SplitDividerMetrics.bandThickness)
            }
            .padding(.leading, SidebarOverlayMetrics.panelInset)
    }
}

/// Geometry shared by the overlay panel and its resize band. The corner-radius
/// formula is the concentric rounded-rectangle rule: an edge inset by `d`
/// receives radius `outerRadius - d`. Reading the outer radius from NSWindow
/// lets macOS define the proportions for every OS/window style.
@MainActor
enum SidebarOverlayMetrics {
    static let panelInset: CGFloat = 4

    static func cornerRadius(windowCornerRadius: CGFloat?, inset: CGFloat) -> CGFloat {
        guard let windowCornerRadius, windowCornerRadius > 0 else { return 0 }
        return max(windowCornerRadius - inset, 0)
    }

    static func resizedWidth(start: CGFloat, delta: CGFloat) -> CGFloat {
        let range = Preferences.sidebarWidthRange
        return min(max(start + delta, CGFloat(range.lowerBound)), CGFloat(range.upperBound))
    }
}

private struct SidebarOverlayBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(in: .rect(cornerRadius: cornerRadius))
                .shadow(color: MactermTheme.border, radius: max(cornerRadius, 1), x: SidebarOverlayMetrics.panelInset)
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(MactermTheme.border, lineWidth: 1)
                }
                .shadow(color: MactermTheme.border, radius: max(cornerRadius, 1), x: SidebarOverlayMetrics.panelInset)
        }
    }
}

/// AppKit drag band on the panel's trailing edge. It owns the resize cursor and
/// keeps receiving drag events after the pointer leaves the narrow hit area,
/// which a SwiftUI gesture layered over a terminal NSView cannot guarantee.
private struct SidebarResizeBand: NSViewRepresentable {
    let widthAtDragStart: () -> CGFloat
    let onResize: (CGFloat) -> Void
    let onResizeStateChanged: (Bool) -> Void

    func makeNSView(context _: Context) -> BandView {
        let view = BandView()
        configure(view)
        return view
    }

    func updateNSView(_ view: BandView, context _: Context) {
        configure(view)
    }

    private func configure(_ view: BandView) {
        view.widthAtDragStart = widthAtDragStart
        view.onResize = onResize
        view.onResizeStateChanged = onResizeStateChanged
    }

    final class BandView: NSView {
        var widthAtDragStart: () -> CGFloat = { CGFloat(Preferences.defaultSidebarWidth) }
        var onResize: (CGFloat) -> Void = { _ in }
        var onResizeStateChanged: (Bool) -> Void = { _ in }

        private var dragOriginX: CGFloat?
        private var startWidth: CGFloat = .init(Preferences.defaultSidebarWidth)
        private var isTransparentToHitTest = false

        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
            true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func cursorUpdate(with _: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDown(with event: NSEvent) {
            dragOriginX = event.locationInWindow.x
            startWidth = widthAtDragStart()
            onResizeStateChanged(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragOriginX else { return }
            NSCursor.resizeLeftRight.set()
            onResize(SidebarOverlayMetrics.resizedWidth(
                start: startWidth,
                delta: event.locationInWindow.x - dragOriginX
            ))
        }

        override func mouseUp(with _: NSEvent) {
            dragOriginX = nil
            onResizeStateChanged(false)
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            isTransparentToHitTest ? nil : super.hitTest(point)
        }

        private func viewBeneath(_ event: NSEvent) -> NSView? {
            isTransparentToHitTest = true
            defer { isTransparentToHitTest = false }
            let target = window?.contentView?.hitTest(event.locationInWindow)
            return target === self ? nil : target
        }

        override func scrollWheel(with event: NSEvent) {
            guard let target = viewBeneath(event) else { return super.scrollWheel(with: event) }
            target.scrollWheel(with: event)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let target = viewBeneath(event) else { return super.rightMouseDown(with: event) }
            target.rightMouseDown(with: event)
        }
    }
}
