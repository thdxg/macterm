import CoreGraphics
import Foundation

/// Where a drag over the workspace would land (#227): a resolved drop target
/// plus the workspace-normalized rect it would occupy.
struct TabDropResolution: Equatable {
    /// The placement grammar shared by pane drags, sidebar-tab merges, and
    /// the headless debug verbs (`pane move`, `tab merge`). Drags resolve
    /// only to `.pane` — `TabDropPlacer` mirrors Ghostty's pane-local
    /// algorithm — while `.rootEdge` and `.divider` stay expressible for the
    /// CLI and `TerminalTab.mergeTree`.
    enum Target: Equatable {
        /// Split the whole workspace on this side: the dropped tree becomes a
        /// new top-level sibling, equalized along that axis.
        case rootEdge(PaneDropZone)
        /// Insert beside this pane at its shared divider, equalizing the axis
        /// — the "side-by-side-by-side, thirds for all" outcome.
        case divider(UUID, PaneDropZone)
        /// Plain local split of this pane (halves it).
        case pane(UUID, PaneDropZone)
    }

    let target: Target
    /// Workspace-normalized rect the dropped tree would occupy — the drop
    /// preview highlights exactly this region, so the user sees the outcome
    /// before releasing.
    let preview: CGRect
}

/// Resolves a workspace-normalized cursor point against the split tree,
/// mirroring Ghostty's drop-zone algorithm (`TerminalSplitDropZone`): the
/// drop is always LOCAL to the hovered pane. Its four triangular regions —
/// formed by the pane's diagonals — pick the closest edge, and the preview
/// is the half of that pane the drop would occupy.
///
/// Deliberately NO workspace-edge or divider escalation (an earlier revision
/// had root-level and divider bands): every cursor position maps to exactly
/// one pane + zone, so no two overlay shapes can describe the same final
/// tree. The old root-edge band duplicated the local split whenever removing
/// the dragged pane left a single sibling — H(a,b) with a in hand showed
/// both a full-width top strip and b's top half for the same V(a,b) outcome.
@MainActor
enum TabDropPlacer {
    static func resolve(point: CGPoint, in root: SplitNode) -> TabDropResolution? {
        // Clamp inside the unit square so an edge-exact drop still lands in a
        // pane (CGRect.contains excludes max edges).
        let p = CGPoint(x: min(max(point.x, 0), 0.9999), y: min(max(point.y, 0), 0.9999))
        guard let hovered = root.paneFrames().first(where: { $0.value.contains(p) }) else { return nil }
        let (paneID, frame) = hovered
        let local = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
        let zone = PaneDropZone.calculate(at: local, in: frame.size)
        return TabDropResolution(target: .pane(paneID, zone), preview: paneHalf(frame, zone))
    }

    private static func paneHalf(_ frame: CGRect, _ zone: PaneDropZone) -> CGRect {
        switch zone {
        case .left: CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .right: CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .top: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .bottom: CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }
}
