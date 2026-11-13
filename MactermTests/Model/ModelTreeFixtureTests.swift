import Foundation
@testable import Macterm
import Testing

/// The tree fixtures of the model core (`server/src/model/trees.json`, design
/// 010 §10). The Zig code applies each case's op to `before` and compares with
/// `after`. This test does the same with the Swift tree code, so the two
/// implementations agree on every case until v1's tree code goes (the
/// cut-over).
@MainActor
struct ModelTreeFixtureTests {
    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Model
        .deletingLastPathComponent() // MactermTests
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("server/src/model/trees.json")

    private static func cases() throws -> [[String: Any]] {
        let data = try Data(contentsOf: fixtureURL)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(root["cases"] as? [[String: Any]])
    }

    /// A fixture tree as a `SplitNode`, and the pane id of each name.
    private static func node(_ value: Any, names: inout [String: UUID]) throws -> SplitNode {
        if let name = value as? String {
            let pane = Pane(projectPath: "/", projectID: UUID())
            names[name] = pane.id
            return .pane(pane)
        }
        let object = try #require(value as? [String: Any])
        let first = try node(#require(object["first"]), names: &names)
        let second = try node(#require(object["second"]), names: &names)
        return try .split(SplitBranch(
            direction: direction(#require(object["dir"] as? String)),
            ratio: CGFloat(#require(object["ratio"] as? Double)),
            first: first,
            second: second
        ))
    }

    private static func string(_ object: [String: Any], _ key: String) throws -> String {
        try #require(object[key] as? String)
    }

    private static func direction(_ text: String) -> SplitDirection {
        text == "horizontal" ? .horizontal : .vertical
    }

    private static func zone(_ text: String) throws -> PaneDropZone {
        switch text {
        case "left": .left
        case "right": .right
        case "top": .top
        case "bottom": .bottom
        default: throw FixtureError.unknown(text)
        }
    }

    enum FixtureError: Error { case unknown(String) }

    /// True when `tree` is the fixture tree `expected`. With `eraseNames`, a
    /// pane name does not count.
    private static func matches(
        _ expected: Any,
        _ tree: SplitNode,
        names: [UUID: String],
        eraseNames: Bool
    ) -> Bool {
        switch tree {
        case let .pane(pane):
            guard let name = expected as? String else { return false }
            return eraseNames || names[pane.id] == name
        case let .split(branch):
            guard let object = expected as? [String: Any],
                  let dir = object["dir"] as? String,
                  let ratio = object["ratio"] as? Double,
                  let first = object["first"],
                  let second = object["second"]
            else { return false }
            return branch.direction == direction(dir)
                && abs(Double(branch.ratio) - ratio) < 1e-9
                && matches(first, branch.first, names: names, eraseNames: eraseNames)
                && matches(second, branch.second, names: names, eraseNames: eraseNames)
        }
    }

    @Test
    func every_case_gives_the_same_tree_as_the_zig_code() throws {
        let all = try Self.cases()
        #expect(all.count >= 10)
        for fixture in all {
            let name = try #require(fixture["name"] as? String)
            let op = try #require(fixture["op"] as? String)
            var ids: [String: UUID] = [:]
            var root = try Self.node(#require(fixture["before"]), names: &ids)
            let erase = fixture["erase_names"] as? Bool ?? false

            switch op {
            case "split":
                let target = try #require(ids[Self.string(fixture, "target")])
                let result = try root.splitting(
                    paneID: target,
                    direction: Self.direction(#require(fixture["dir"] as? String)),
                    position: fixture["position"] as? String == "first" ? .first : .second,
                    projectPath: "/",
                    projectID: UUID()
                )
                root = result.node
                try ids[#require(fixture["new"] as? String)] = try #require(result.newPaneID)
            case "remove":
                let want = try #require(fixture["result"] as? String)
                let target = try #require(ids[Self.string(fixture, "pane")])
                if let removed = root.removing(paneID: target) {
                    root = removed
                    #expect(want != "only_pane", "\(name)")
                } else {
                    // v1 answers nil for the last pane: the tab closes.
                    #expect(want == "only_pane", "\(name)")
                }
            case "rebalance":
                root.rebalanced()
            case "swap":
                let x = try #require(ids[Self.string(fixture, "x")])
                let y = try #require(ids[Self.string(fixture, "y")])
                root = root.swappingPanes(x, y)
            case "insert":
                var fresh: [String: UUID] = [:]
                let inserted = try Self.node(#require(fixture["node"]), names: &fresh)
                ids.merge(fresh) { current, _ in current }
                let zone = try Self.zone(#require(fixture["zone"] as? String))
                let dest = try #require(ids[Self.string(fixture, "dest")])
                let result = root.inserting(
                    node: inserted,
                    at: dest,
                    direction: zone.splitDirection,
                    position: zone.splitPosition
                )
                #expect(result.inserted, "\(name)")
                root = result.node
            case "grid":
                let source = try #require(ids[Self.string(fixture, "source")])
                let tab = TerminalTab(id: UUID(), splitRoot: root, focusedPaneID: source)
                let created = try tab.makeGrid(
                    paneID: source,
                    rows: #require(fixture["rows"] as? Int),
                    columns: #require(fixture["columns"] as? Int)
                )
                #expect(!created.isEmpty, "\(name)")
                root = tab.splitRoot
            default:
                throw FixtureError.unknown(op)
            }

            let reverse = Dictionary(uniqueKeysWithValues: ids.map { ($0.value, $0.key) })
            let after = try #require(fixture["after"])
            #expect(Self.matches(after, root, names: reverse, eraseNames: erase), "case: \(name)")
        }
    }
}
