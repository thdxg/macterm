import Foundation
@testable import Macterm

/// Test-only DSL for building `SplitNode` trees and tracking each leaf's UUID
/// by a human-readable name.
///
/// Usage:
///
///     let (tree, ids) = build {
///         H(pane("l1"), V(pane("r1"), pane("r2")))
///     }
///     // ids["l1"], ids["r1"], ids["r2"]
///
/// The builder returns a named subtree (a `TreeSpec`) that can be nested. All
/// leaf names must be unique within a single build; duplicate names will trip a
/// precondition so tests fail loudly instead of silently overwriting.
@MainActor
struct TreeSpec {
    /// Node construction is deferred until `build` so that each run produces
    /// fresh `Pane` instances (and therefore fresh UUIDs) even when the same
    /// `TreeSpec` literal is reused across tests.
    let make: (inout [String: UUID]) -> SplitNode
}

@MainActor
func pane(_ name: String, projectPath: String = "/") -> TreeSpec {
    TreeSpec { registry in
        precondition(registry[name] == nil, "duplicate pane name in tree: \(name)")
        let p = Pane(projectPath: projectPath)
        registry[name] = p.id
        return .pane(p)
    }
}

@MainActor
func H(_ left: TreeSpec, _ right: TreeSpec, ratio: CGFloat = 0.5) -> TreeSpec {
    TreeSpec { registry in
        let l = left.make(&registry)
        let r = right.make(&registry)
        return .split(SplitBranch(direction: .horizontal, ratio: ratio, first: l, second: r))
    }
}

@MainActor
func V(_ top: TreeSpec, _ bottom: TreeSpec, ratio: CGFloat = 0.5) -> TreeSpec {
    TreeSpec { registry in
        let t = top.make(&registry)
        let b = bottom.make(&registry)
        return .split(SplitBranch(direction: .vertical, ratio: ratio, first: t, second: b))
    }
}

/// Materializes a `TreeSpec` into a concrete `SplitNode` and a name→UUID map.
@MainActor
func build(_ spec: TreeSpec) -> (tree: SplitNode, ids: [String: UUID]) {
    var ids: [String: UUID] = [:]
    let tree = spec.make(&ids)
    return (tree, ids)
}
