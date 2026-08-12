import CoreGraphics
import Foundation

enum SplitDirection: String, Codable { case horizontal, vertical }
enum SplitPosition { case first, second }

/// Which edge of a pane a dragged pane is dropped onto. Determines how the
/// destination is split and on which side the dragged pane lands.
enum PaneDropZone: Equatable {
    case left
    case right
    case top
    case bottom

    /// The drop zone for a cursor position inside a pane: the four triangular
    /// regions formed by the pane's diagonals, i.e. whichever edge is closest.
    static func calculate(at point: CGPoint, in size: CGSize) -> PaneDropZone {
        guard size.width > 0, size.height > 0 else { return .right }
        let distToLeft = point.x / size.width
        let distToRight = 1 - distToLeft
        let distToTop = point.y / size.height
        let distToBottom = 1 - distToTop
        let minDist = min(distToLeft, distToRight, distToTop, distToBottom)
        if minDist == distToLeft { return .left }
        if minDist == distToRight { return .right }
        if minDist == distToTop { return .top }
        return .bottom
    }

    var splitDirection: SplitDirection {
        switch self {
        case .left,
             .right: .horizontal
        case .top,
             .bottom: .vertical
        }
    }

    var splitPosition: SplitPosition {
        switch self {
        case .left,
             .top: .first
        case .right,
             .bottom: .second
        }
    }
}

/// Recursive split tree. Each leaf is a `Pane`, each branch splits two subtrees.
enum SplitNode: Identifiable {
    case pane(Pane)
    indirect case split(SplitBranch)

    var id: UUID {
        switch self {
        case let .pane(p): p.id
        case let .split(b): b.id
        }
    }
}

@MainActor @Observable
final class SplitBranch: Identifiable {
    let id = UUID()
    var direction: SplitDirection
    var ratio: CGFloat
    var first: SplitNode
    var second: SplitNode

    init(direction: SplitDirection, ratio: CGFloat = 0.5, first: SplitNode, second: SplitNode) {
        self.direction = direction
        self.ratio = ratio
        self.first = first
        self.second = second
    }
}

// MARK: - Tree operations

@MainActor
extension SplitNode {
    func splitting(
        paneID: UUID,
        direction: SplitDirection,
        position: SplitPosition,
        projectPath: String,
        projectID: UUID,
        command: String? = nil
    ) -> (node: SplitNode, newPaneID: UUID?) {
        switch self {
        case let .pane(p) where p.id == paneID:
            // Inherit the source pane's session slug so the new sibling groups
            // under the same project in `zmx ls`.
            let newPane = Pane(
                projectPath: projectPath, projectID: projectID, sessionSlug: p.sessionSlug, command: command
            )
            let first: SplitNode = position == .first ? .pane(newPane) : .pane(p)
            let second: SplitNode = position == .first ? .pane(p) : .pane(newPane)
            return (.split(SplitBranch(direction: direction, first: first, second: second)), newPane.id)
        case .pane:
            return (self, nil)
        case let .split(branch):
            let (newFirst, id1) = branch.first.splitting(
                paneID: paneID,
                direction: direction,
                position: position,
                projectPath: projectPath,
                projectID: projectID,
                command: command
            )
            branch.first = newFirst
            if id1 != nil { return (.split(branch), id1) }
            let (newSecond, id2) = branch.second.splitting(
                paneID: paneID,
                direction: direction,
                position: position,
                projectPath: projectPath,
                projectID: projectID,
                command: command
            )
            branch.second = newSecond
            return (.split(branch), id2)
        }
    }

    /// Insert an existing pane next to the pane `destinationID`, wrapping the
    /// destination in a new split with `pane` at `position`. The structural
    /// counterpart of `splitting`, used to re-attach a pane during a
    /// drag-and-drop move. Returns `inserted: false` (tree unchanged) when the
    /// destination isn't in the tree.
    func inserting(
        pane: Pane,
        at destinationID: UUID,
        direction: SplitDirection,
        position: SplitPosition
    ) -> (node: SplitNode, inserted: Bool) {
        inserting(node: .pane(pane), at: destinationID, direction: direction, position: position)
    }

    /// Insert a whole subtree next to the pane `destinationID`, wrapping the
    /// destination in a new split with `node` at `position`. Generalizes the
    /// single-pane variant so a dragged tab's entire split tree can land beside
    /// a pane in one structural move (its panes and surfaces reused as-is).
    func inserting(
        node: SplitNode,
        at destinationID: UUID,
        direction: SplitDirection,
        position: SplitPosition
    ) -> (node: SplitNode, inserted: Bool) {
        switch self {
        case let .pane(p) where p.id == destinationID:
            let first: SplitNode = position == .first ? node : .pane(p)
            let second: SplitNode = position == .first ? .pane(p) : node
            return (.split(SplitBranch(direction: direction, first: first, second: second)), true)
        case .pane:
            return (self, false)
        case let .split(branch):
            let (newFirst, ok1) = branch.first.inserting(
                node: node, at: destinationID, direction: direction, position: position
            )
            branch.first = newFirst
            if ok1 { return (.split(branch), true) }
            let (newSecond, ok2) = branch.second.inserting(
                node: node, at: destinationID, direction: direction, position: position
            )
            branch.second = newSecond
            return (.split(branch), ok2)
        }
    }

    func removing(paneID: UUID) -> SplitNode? {
        switch self {
        case let .pane(p) where p.id == paneID: return nil
        case .pane: return self
        case let .split(branch):
            if case let .pane(p) = branch.first, p.id == paneID { return branch.second }
            if case let .pane(p) = branch.second, p.id == paneID { return branch.first }
            if branch.first.contains(paneID: paneID), let n = branch.first.removing(paneID: paneID) {
                branch.first = n
                return .split(branch)
            }
            if branch.second.contains(paneID: paneID), let n = branch.second.removing(paneID: paneID) {
                branch.second = n
                return .split(branch)
            }
            return self
        }
    }

    func contains(paneID: UUID) -> Bool {
        switch self {
        case let .pane(p): p.id == paneID
        case let .split(b): b.first.contains(paneID: paneID) || b.second.contains(paneID: paneID)
        }
    }

    func allPanes() -> [Pane] {
        switch self {
        case let .pane(p): [p]
        case let .split(b): b.first.allPanes() + b.second.allPanes()
        }
    }

    func findPane(id: UUID) -> Pane? {
        switch self {
        case let .pane(p): p.id == id ? p : nil
        case let .split(b): b.first.findPane(id: id) ?? b.second.findPane(id: id)
        }
    }

    func paneFrames(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [UUID: CGRect] {
        switch self {
        case let .pane(p):
            return [p.id: rect]
        case let .split(b):
            let r = min(max(b.ratio, 0), 1)
            if b.direction == .horizontal {
                let w1 = rect.width * r
                let r1 = CGRect(x: rect.minX, y: rect.minY, width: w1, height: rect.height)
                let r2 = CGRect(x: rect.minX + w1, y: rect.minY, width: rect.width - w1, height: rect.height)
                return b.first.paneFrames(in: r1).merging(b.second.paneFrames(in: r2)) { a, _ in a }
            }
            let h1 = rect.height * r
            let r1 = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h1)
            let r2 = CGRect(x: rect.minX, y: rect.minY + h1, width: rect.width, height: rect.height - h1)
            return b.first.paneFrames(in: r1).merging(b.second.paneFrames(in: r2)) { a, _ in a }
        }
    }

    /// Find the nearest pane in a direction from the currently focused pane.
    func nearestPane(from focusedID: UUID, direction: PaneFocusDirection) -> UUID? {
        let frames = paneFrames()
        guard let focusedFrame = frames[focusedID] else { return nil }
        var bestID: UUID?
        var bestDist: CGFloat = .greatestFiniteMagnitude
        for (id, frame) in frames where id != focusedID {
            let isCandidate: Bool = switch direction {
            case .left: frame.midX < focusedFrame.midX && frame.maxY > focusedFrame.minY && frame.minY < focusedFrame.maxY
            case .right: frame.midX > focusedFrame.midX && frame.maxY > focusedFrame.minY && frame.minY < focusedFrame.maxY
            case .up: frame.midY < focusedFrame.midY && frame.maxX > focusedFrame.minX && frame.minX < focusedFrame.maxX
            case .down: frame.midY > focusedFrame.midY && frame.maxX > focusedFrame.minX && frame.minX < focusedFrame.maxX
            }
            guard isCandidate else { continue }
            let dist: CGFloat = switch direction {
            case .left,
                 .right: abs(focusedFrame.midX - frame.midX)
            case .up,
                 .down: abs(focusedFrame.midY - frame.midY)
            }
            if dist < bestDist { bestDist = dist
                bestID = id
            }
        }
        return bestID
    }
}

enum PaneFocusDirection { case left, right, up, down }

@MainActor
extension SplitNode {
    /// Rebalance all ratios so sibling panes along each direction share space
    /// evenly. Mutates in place; returns the receiver for chaining.
    @discardableResult
    func rebalanced() -> SplitNode {
        if case let .split(branch) = self {
            let leftUnits = branch.first.tileUnits(along: branch.direction)
            let rightUnits = branch.second.tileUnits(along: branch.direction)
            let total = leftUnits + rightUnits
            if total > 0 {
                branch.ratio = CGFloat(leftUnits) / CGFloat(total)
            }
            _ = branch.first.rebalanced()
            _ = branch.second.rebalanced()
        }
        return self
    }

    /// Number of "cells" this subtree contributes when laid out along the given
    /// direction. Same-direction descendants expand to their leaf count;
    /// different-direction or leaf nodes count as a single cell. Also feeds
    /// `TabDropPlacer`'s preview widths (#227).
    func tileUnits(along direction: SplitDirection) -> Int {
        switch self {
        case .pane: 1
        case let .split(b):
            b.direction == direction
                ? b.first.tileUnits(along: direction) + b.second.tileUnits(along: direction)
                : 1
        }
    }

    /// Adjust the ratio of the nearest ancestor split in the given direction by `delta`.
    /// Returns the receiver if no matching split is found.
    func resizing(paneID: UUID, direction: PaneFocusDirection, delta: CGFloat) -> SplitNode {
        let axis: SplitDirection = (direction == .left || direction == .right) ? .horizontal : .vertical
        let sign: CGFloat = (direction == .right || direction == .down) ? 1 : -1
        _ = applyResize(paneID: paneID, axis: axis, delta: sign * delta)
        return self
    }

    /// Walks the tree and applies the delta to the closest matching-axis ancestor
    /// of the given pane. Returns true if the ratio was actually adjusted.
    @discardableResult
    private func applyResize(paneID: UUID, axis: SplitDirection, delta: CGFloat) -> Bool {
        guard case let .split(branch) = self else { return false }
        let firstHas = branch.first.contains(paneID: paneID)
        let secondHas = branch.second.contains(paneID: paneID)
        guard firstHas || secondHas else { return false }
        // Recurse first — deeper (closer) ancestor wins.
        let child: SplitNode = firstHas ? branch.first : branch.second
        if child.applyResize(paneID: paneID, axis: axis, delta: delta) { return true }
        // No deeper match; if this branch matches the axis, apply here.
        if branch.direction == axis {
            branch.ratio = min(max(branch.ratio + delta, 0.15), 0.85)
            return true
        }
        return false
    }

    /// Set the ratio of the nearest ancestor branch of `paneID` whose direction
    /// matches `axis` to an absolute value (clamped to 0.15…0.85). The control
    /// CLI's `pane resize-split` uses this for a deterministic geometry, in
    /// contrast to `applyResize`'s relative nudge (the keybind path). Returns
    /// true iff a matching branch was found and set.
    @discardableResult
    func settingRatio(paneID: UUID, axis: SplitDirection, ratio: CGFloat) -> Bool {
        guard case let .split(branch) = self else { return false }
        let firstHas = branch.first.contains(paneID: paneID)
        let secondHas = branch.second.contains(paneID: paneID)
        guard firstHas || secondHas else { return false }
        // Deeper (closer) ancestor wins, matching applyResize.
        let child: SplitNode = firstHas ? branch.first : branch.second
        if child.settingRatio(paneID: paneID, axis: axis, ratio: ratio) { return true }
        if branch.direction == axis {
            branch.ratio = min(max(ratio, 0.15), 0.85)
            return true
        }
        return false
    }
}
