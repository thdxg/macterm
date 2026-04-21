import Foundation
@testable import Macterm

/// Renders a `SplitNode` back to the `TreeBuilder` DSL string so tests can
/// assert tree topology with a readable one-liner.
///
///     render(.split(SplitBranch(direction: .horizontal, ...))) == "H(l1, V(r1, r2))"
///
/// Leaf names come from the `ids` map passed in; any unknown pane is rendered
/// as `?` so tests fail on an assertion with obvious output instead of silently
/// matching something like a UUID.
@MainActor
func render(_ node: SplitNode, ids: [String: UUID]) -> String {
    let reverse = Dictionary(uniqueKeysWithValues: ids.map { ($0.value, $0.key) })
    return renderNode(node, reverse: reverse)
}

@MainActor
private func renderNode(_ node: SplitNode, reverse: [UUID: String]) -> String {
    switch node {
    case let .pane(p):
        return reverse[p.id] ?? "?"
    case let .split(b):
        let prefix = b.direction == .horizontal ? "H" : "V"
        let a = renderNode(b.first, reverse: reverse)
        let c = renderNode(b.second, reverse: reverse)
        return "\(prefix)(\(a), \(c))"
    }
}
