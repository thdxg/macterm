import AppKit
import SwiftUI

/// Entry point for a tab's split tree. Renders the recursive `SplitTreeView`
/// by default, or the flat `AnimatedSplitView` under Settings → Experimental
/// → Animate splits. Both take the tab's whole tree; zoom is resolved here
/// (the recursive view renders the zoomed pane alone, the flat view keeps
/// every tile mounted so zoom can animate).
struct SplitRootView: View {
    /// Identity for the animated view: a tab switch remounts it, so the
    /// incoming tab's panes appear in place instead of sliding in one by one.
    let tabID: UUID
    let root: SplitNode
    let focusedPaneID: UUID?
    let zoomedPaneID: UUID?
    let isActiveProject: Bool
    let projectID: UUID
    var nonLeaderPaneIDs: Set<UUID> = []
    let onFocusPane: (UUID) -> Void
    let onSplit: (UUID, SplitDirection, SplitPosition) -> Void
    let onClosePane: (UUID) -> Void
    var onCommandFinished: (UUID) -> Void = { _ in }
    var onAdaptiveBackgroundChange: (UUID, CGColor?) -> Void = { _, _ in }
    var onToggleZoom: (UUID) -> Void = { _ in }
    var paneDrop: PaneDropContext?

    var body: some View {
        if Preferences.shared.animatedSplits {
            AnimatedSplitView(
                root: root,
                focusedPaneID: focusedPaneID,
                zoomedPaneID: zoomedPaneID,
                isActiveProject: isActiveProject,
                nonLeaderPaneIDs: nonLeaderPaneIDs,
                onFocusPane: onFocusPane,
                onSplit: onSplit,
                onClosePane: onClosePane,
                onCommandFinished: onCommandFinished,
                onAdaptiveBackgroundChange: onAdaptiveBackgroundChange,
                onToggleZoom: onToggleZoom,
                paneDrop: paneDrop
            )
            .id(tabID)
        } else {
            let rendered = renderedNode
            SplitTreeView(
                node: rendered,
                focusedPaneID: focusedPaneID,
                zoomedPaneID: zoomedPaneID,
                isActiveProject: isActiveProject,
                projectID: projectID,
                nonLeaderPaneIDs: nonLeaderPaneIDs,
                onFocusPane: onFocusPane,
                onSplit: onSplit,
                onClosePane: onClosePane,
                onCommandFinished: onCommandFinished,
                onAdaptiveBackgroundChange: onAdaptiveBackgroundChange,
                onToggleZoom: onToggleZoom,
                paneDrop: paneDrop
            )
            .id(rendered.id)
        }
    }

    /// While zoomed the recursive view renders only the zoomed pane.
    private var renderedNode: SplitNode {
        if let zoomedPaneID, let pane = root.findPane(id: zoomedPaneID) {
            return .pane(pane)
        }
        return root
    }
}

/// Timing shared by every split animation: Hyprland's `slide` style, a short
/// ease-out along the split's axis. A pane comes in from, and leaves
/// through, its own outer edge of the split: the right pane of a side-by-
/// side split slides right, the left pane left; the bottom pane of a stacked
/// split slides down, the top pane up.
enum SplitAnimation {
    static let duration: TimeInterval = 0.3
    static var curve: Animation { .smooth(duration: duration) }
}

/// The split tree laid out flat: every pane is a child of one ZStack, keyed
/// by pane ID, at the absolute frame `SplitLayout` resolves for it. A tree
/// change is then frames moving on stable identities, which SwiftUI animates
/// — a new pane slides in along its split's axis while its sibling makes
/// room, a closing pane slides back out as the sibling reclaims the strip,
/// zoom grows a pane over the layout, a pane dragged to another branch
/// travels there. The recursive `SplitTreeView` can't animate any of that,
/// because re-nesting a leaf changes its structural identity.
///
/// Rules that keep this honest with the pane-owned NSView model:
///
/// - **Every motion is a frame change, never a transition.** A live pane is
///   an NSView, and SwiftUI positions platform views by frame only —
///   `.scaleEffect` and the `.scale`/`.move` transitions leave the view where
///   it is and at best fade it (verified on the debug app). So a leaf this
///   view has not laid out before is placed collapsed against its own outer
///   edge of the split (`SplitLayout.collapsed`) and, on the next turn,
///   animated to its tile; its new divider rides the seam with it. Leaves
///   present at first appearance (a tab switch remounts the view) are known
///   from the start and don't slide.
/// - **Nothing ever moves over another pane.** Pane backgrounds are
///   transparent (the fork's `background-default-transparent`; the window
///   paints the tint), so a pane crossing another would show text through
///   text, and an empty new pane is invisible anyway. The new pane grows out
///   of the seam exactly as fast as its sibling shrinks (both edges are one
///   linear animation), and a closing pane's ghost is clipped to the strip
///   its sibling has not yet reclaimed.
/// - **A closing pane is drawn as a ghost, not animated live.**
///   `Pane.destroySurface` nils the view and detaches it a tick later, so
///   moving the leaf itself would slide an empty host. The model snapshots
///   the pane's last frame (`Pane.closingSnapshot`) WITHOUT a background
///   fill, so over the window tint it looks exactly as the pane did — an
///   opaque ghost flashed to full opacity in a translucent window. A pane
///   that merely moved to another tab has no snapshot and simply disappears.
///   The ghost carries the seam's hairline too (`SplitLayout.seamHairline`),
///   since the branch's real divider is gone with the branch.
/// - **Zoom keeps the other tiles mounted**, at opacity 0 beneath the zoomed
///   pane, so unzoom can slide them back without the orphan-and-reattach
///   round trip a remount costs. They sleep through
///   `GhosttyTerminalNSView.hiddenInLayout`. Dividers ARE removed while
///   zoomed: a grab band is an NSView and would catch drags through the
///   zoomed pane even when invisible.
/// - **Only structure animates.** The animation is keyed to
///   `SplitLayout.animationKey` (pane identities and axes plus the zoomed
///   pane), never to ratios, so a divider drag lands immediately and a
///   window resize doesn't animate the tiles.
/// - Every animation frame resizes each moving pane's surface, the same path
///   a divider drag takes. Reduce Motion turns the animation off.
struct AnimatedSplitView: View {
    let root: SplitNode
    let focusedPaneID: UUID?
    let zoomedPaneID: UUID?
    let isActiveProject: Bool
    let nonLeaderPaneIDs: Set<UUID>
    let onFocusPane: (UUID) -> Void
    let onSplit: (UUID, SplitDirection, SplitPosition) -> Void
    let onClosePane: (UUID) -> Void
    let onCommandFinished: (UUID) -> Void
    let onAdaptiveBackgroundChange: (UUID, CGColor?) -> Void
    let onToggleZoom: (UUID) -> Void
    let paneDrop: PaneDropContext?

    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @State
    private var ghosts: [ClosingGhost] = []

    /// Pane and branch IDs this view has laid out in place. nil until the
    /// first body, so everything present at appearance is never "new".
    @State
    private var settledIDs: Set<UUID>?

    /// A leaf as displayed: its resolved tile, or the whole container when
    /// it is the zoomed pane; hidden when another pane is zoomed.
    private struct PlacedLeaf: Identifiable, Equatable {
        let pane: Pane
        let rect: CGRect
        let placement: SplitLayout.Placement?
        let hidden: Bool

        var id: UUID { pane.id }

        static func == (lhs: PlacedLeaf, rhs: PlacedLeaf) -> Bool {
            lhs.pane === rhs.pane && lhs.rect == rhs.rect && lhs.placement == rhs.placement
                && lhs.hidden == rhs.hidden
        }
    }

    /// A closed pane's last frame, sliding out of the strip it left.
    private struct ClosingGhost: Identifiable {
        let id: UUID
        let rect: CGRect
        let placement: SplitLayout.Placement?
        let snapshot: PanePreview
        var leaving = false
    }

    private var animation: Animation? {
        reduceMotion ? nil : SplitAnimation.curve
    }

    var body: some View {
        GeometryReader { geo in
            let bounds = CGRect(origin: .zero, size: geo.size)
            let layout = SplitLayout.resolve(root, in: bounds)
            // A zoom onto a pane that is no longer in the tree is no zoom.
            let zoomed = zoomedPaneID.flatMap { id in layout.leaves.contains { $0.id == id } ? id : nil }
            let isSplit = layout.leaves.count > 1 && zoomed == nil
            let placed = layout.leaves.map { leaf in
                PlacedLeaf(
                    pane: leaf.pane,
                    rect: leaf.id == zoomed ? bounds : leaf.rect,
                    placement: leaf.placement,
                    hidden: zoomed != nil && leaf.id != zoomed
                )
            }
            let arrivingIDs = settledIDs.map { settled in
                Set(placed.map(\.id).filter { !settled.contains($0) })
            } ?? []

            ZStack(alignment: .topLeading) {
                ForEach(placed) { leaf in
                    let rect = arrivingIDs.contains(leaf.id)
                        ? SplitLayout.collapsed(leaf.rect, placement: leaf.placement)
                        : leaf.rect
                    leafView(leaf.pane, isSplit: isSplit)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .opacity(leaf.hidden ? 0 : 1)
                        .allowsHitTesting(!leaf.hidden)
                        .zIndex(leaf.id == zoomed ? 1 : 0)
                        // No transition either way: the slide-in is the frame
                        // change above, and a dead leaf must vanish in the
                        // same frame its ghost appears rather than linger
                        // over it.
                        .transition(.identity)
                        .onAppear { settle(leaf.id) }
                        .onChange(of: leaf.hidden, initial: true) { _, hidden in
                            leaf.pane.nsView?.hiddenInLayout = hidden
                        }
                }

                if zoomed == nil {
                    ForEach(layout.dividers) { divider in
                        dividerView(divider, arrivingIDs: arrivingIDs)
                    }
                }

                ForEach(ghosts) { ghost in
                    ghostView(ghost)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(animation, value: SplitLayout.animationKey(of: root, zoomedPaneID: zoomed))
            .onAppear {
                settledIDs = Set(placed.map(\.id)).union(layout.dividers.map(\.id))
            }
            .onChange(of: placed) { old, new in
                ghostClosedLeaves(from: old, to: new)
            }
        }
    }

    private func leafView(_ pane: Pane, isSplit: Bool) -> some View {
        SplitLeafView(
            pane: pane,
            isFocused: focusedPaneID == pane.id && isActiveProject,
            isZoomed: zoomedPaneID == pane.id,
            isSplit: isSplit,
            isNonLeaderMirror: nonLeaderPaneIDs.contains(pane.id),
            onFocus: { onFocusPane(pane.id) },
            onProcessExit: { onClosePane(pane.id) },
            onCommandFinished: { onCommandFinished(pane.id) },
            onAdaptiveBackgroundChange: { onAdaptiveBackgroundChange(pane.id, $0) },
            onSplitRequest: { dir, position in onSplit(pane.id, dir, position) },
            onZoomRequest: { onToggleZoom(pane.id) },
            paneDrop: paneDrop
        )
    }

    /// The hairline and, over it, the grab band (#260) — layered above both
    /// panes for the same reason `SplitDividerView` overlays it: a pane is an
    /// NSView that wins AppKit hit testing, so a band beneath one is no
    /// target. A divider born with an arriving pane starts at that pane's
    /// outer edge and travels in with the seam; one born between two settled
    /// panes (a pane dropped beside another) just fades in. A divider whose
    /// branch collapses goes at once: fading in place, it hung as a stray
    /// hairline where the seam no longer was while the ghost slid out.
    @ViewBuilder
    private func dividerView(_ divider: SplitLayout.Divider, arrivingIDs: Set<UUID>) -> some View {
        let arrivingSide: SplitPosition? = if arrivingIDs.contains(divider.secondID) {
            .second
        } else if arrivingIDs.contains(divider.firstID) {
            .first
        } else {
            nil
        }
        let placement = arrivingSide.map {
            SplitLayout.Placement(axis: divider.axis, position: $0, branchRect: divider.branchRect)
        }
        let rect = SplitLayout.collapsed(divider.rect, placement: placement)
        let bandRect = SplitLayout.collapsed(divider.bandRect, placement: placement)

        Rectangle()
            .fill(MactermTheme.border)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .transition(.asymmetric(insertion: .opacity, removal: .identity))
            .onAppear { settle(divider.id) }

        ResizeDragBand(
            axis: divider.axis == .horizontal ? .horizontal : .vertical,
            valueAtDragStart: { divider.branch.ratio },
            resizedValue: { start, delta in
                SplitDividerMetrics.draggedRatio(start: start, delta: delta, total: divider.total)
            },
            onResize: { divider.branch.ratio = $0 }
        )
        .frame(width: bandRect.width, height: bandRect.height)
        .position(x: bandRect.midX, y: bandRect.midY)
        .transition(.asymmetric(insertion: .opacity, removal: .identity))
    }

    /// The ghost's image is drawn at the size the pane actually had on
    /// screen (`PanePreview.pointSize`), never stretched to the tile: close
    /// a pane while its sibling is still growing from an earlier close and
    /// the snapshot is of a smaller, mid-resize surface — filling the model's
    /// tile with it scaled the text non-uniformly. It slides toward the
    /// pane's outer edge by the tile's length; the window it is seen through
    /// shrinks from the tile to nothing against that same edge, exactly as
    /// fast as the sibling advances into the strip. The branch's divider,
    /// removed with the branch, is stood in for by a hairline on the
    /// window's seam edge, so the divider travels with the retile.
    @ViewBuilder
    private func ghostView(_ ghost: ClosingGhost) -> some View {
        let window = ghost.leaving ? SplitLayout.collapsed(ghost.rect, placement: ghost.placement) : ghost.rect
        let shift = ghost.leaving ? SplitLayout.slideOutShift(for: ghost.rect, placement: ghost.placement) : .zero
        ZStack(alignment: .topLeading) {
            if let image = ghost.snapshot.image, let size = ghost.snapshot.pointSize {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: size.width, height: size.height)
                    .offset(x: shift.width, y: shift.height)
            }
        }
        .frame(width: window.width, height: window.height, alignment: .topLeading)
        .clipped()
        .position(x: window.midX, y: window.midY)
        .zIndex(2)
        .allowsHitTesting(false)
        // Placed and dropped without transitions: it replaces the pane in the
        // same frame, and is removed only once it has slid out of view.
        .transition(.identity)
        .onAppear { slideOut(ghost.id) }

        if let placement = ghost.placement {
            let seam = SplitLayout.seamHairline(of: window, placement: placement)
            Rectangle()
                .fill(MactermTheme.border)
                .frame(width: seam.width, height: seam.height)
                .position(x: seam.midX, y: seam.midY)
                .zIndex(2)
                .allowsHitTesting(false)
                .transition(.identity)
        }
    }

    /// Leaves that left the layout with a closing snapshot become ghosts,
    /// placed where they were; each starts its slide from its own
    /// `onAppear` (`slideOut`). A hidden tile (closed behind a zoom, e.g.
    /// over the CLI) was never visible and gets no ghost.
    private func ghostClosedLeaves(from old: [PlacedLeaf], to new: [PlacedLeaf]) {
        let remaining = Set(new.map(\.id))
        let closing = old.filter { !remaining.contains($0.id) && !$0.hidden }
            .compactMap { leaf in
                leaf.pane.closingSnapshot.map {
                    ClosingGhost(id: leaf.id, rect: leaf.rect, placement: leaf.placement, snapshot: $0)
                }
            }
        guard !closing.isEmpty else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            ghosts.append(contentsOf: closing)
        }
    }

    /// Start a ghost's slide and drop it once the slide is over.
    ///
    /// Both this and `settle` run from `onAppear`, which fires in the same
    /// frame as the layout change that created the view — the sibling's own
    /// frame animation started in that frame, and starting ours a run-loop
    /// turn later left the two visibly out of step at the seam (an ease-out
    /// covers a lot of ground in its first turn). The view has been laid out
    /// at rest by then, so the animation has a start to interpolate from.
    private func slideOut(_ id: UUID) {
        withAnimation(animation) {
            for index in ghosts.indices where ghosts[index].id == id {
                ghosts[index].leaving = true
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(animation == nil ? 0 : SplitAnimation.duration))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                ghosts.removeAll { $0.id == id }
            }
        }
    }

    /// A leaf or divider laid out collapsed moves to its place under the
    /// split animation. No-op before the first body has recorded what was
    /// present at appearance (see `settledIDs`), and for anything already
    /// settled.
    private func settle(_ id: UUID) {
        guard let settled = settledIDs, !settled.contains(id) else { return }
        withAnimation(animation) {
            settledIDs?.insert(id)
        }
    }
}
