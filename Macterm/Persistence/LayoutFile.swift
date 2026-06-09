import Foundation
import Yams

/// A hand-authored, committable declaration of a project's pane layout and the
/// processes each pane should run. Distinct from `WorkspaceSnapshot` (the
/// machine-written restore state): a layout file is an *input* the user writes
/// and commits, applied on demand to produce a live workspace.
///
/// Lives at `.macterm/layout.yaml` relative to the project root. Each tab is
/// itself a node (no `layout:` wrapper) with an optional `name:`: a leaf carries
/// the pane fields (`cwd`/`run`/`shell`) directly, and a split carries
/// `{ split: { direction: <dir>, ratio: <0..1>, first: <node>, second: <node> } }`.
/// See `LayoutNode` for the node wire form and an example.
struct LayoutFile: Codable, Equatable {
    /// Name of the project this layout was authored for. Written by `save`;
    /// on `apply`, a mismatch against the active project prompts a confirmation.
    /// Optional — a file without it applies to any project without warning.
    var name: String?
    var tabs: [LayoutTab]
}

/// A tab: a layout node plus an optional `name:` (the tab's title, matched
/// against live tabs on `apply`). The node fields live at the same level as
/// `name` — there's no `layout:` wrapper. `name` is tab-level only; inner split
/// children are plain nodes.
struct LayoutTab: Equatable {
    var name: String?
    var layout: LayoutNode
}

extension LayoutTab: Codable {
    init(from decoder: Decoder) throws {
        let dto = try LayoutNodeDTO(from: decoder)
        name = dto.name
        layout = try LayoutNode(fromDTO: dto, codingPath: decoder.codingPath)
    }

    func encode(to encoder: Encoder) throws {
        try layout.dto(name: name).encode(to: encoder)
    }
}

/// A node in the split tree, exposed as an enum to the rest of the app. Its
/// `Codable` conformance routes through a fully *synthesized* DTO struct
/// (`LayoutNodeDTO`) decoded via a single-value container, rather than a custom
/// keyed-container `init(from:)`. This is deliberate: Yams' decoder surfaces a
/// raw `Node` where a `Mapping` is expected when a custom `init(from:)` opens a
/// keyed container nested inside another custom-decoded value (the recursive
/// split case). Letting Yams drive synthesized decoding of the DTO sidesteps it.
///
/// Wire form: a node is a *split* when it has a `split:` mapping (`direction`,
/// optional `ratio`, and `first`/`second` children); otherwise it's a *leaf*,
/// and the pane fields (`cwd`/`run`/`shell`) apply directly — no `pane:`
/// wrapper. A bare `{}` is a plain-shell leaf.
///
///     split:
///       direction: horizontal
///       ratio: 0.6
///       first:  { run: "npm run dev" }
///       second: { }
indirect enum LayoutNode: Equatable {
    case pane(LayoutPane)
    case split(LayoutBranch)
}

/// The nested `split:` mapping of a split node.
struct LayoutSplitDTO: Codable, Equatable {
    var direction: SplitDirection
    var ratio: Double?
    var first: LayoutNodeBox?
    var second: LayoutNodeBox?
}

/// Synthesized-Codable wire form of a tab/node. A node is a *split* when it has
/// a `split:` mapping; otherwise it's a *leaf*, and the pane fields
/// (`cwd`/`run`/`shell`) apply directly at this level — no `pane:` wrapper. A
/// bare `{}` is a plain-shell leaf. `name` is only meaningful at the tab level.
struct LayoutNodeDTO: Codable, Equatable {
    /// Tab-level only.
    var name: String?
    // Leaf fields (flattened — see LayoutPane).
    var cwd: String?
    var run: String?
    var shell: String?
    /// Split field (nested mapping).
    var split: LayoutSplitDTO?
}

/// Indirection box so the synthesized `Codable` DTO can hold child nodes
/// (structs can't directly contain themselves).
final class LayoutNodeBox: Codable, Equatable {
    let node: LayoutNode
    init(_ node: LayoutNode) {
        self.node = node
    }

    init(from decoder: Decoder) throws {
        node = try LayoutNode(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try node.encode(to: encoder)
    }

    static func == (lhs: LayoutNodeBox, rhs: LayoutNodeBox) -> Bool {
        lhs.node == rhs.node
    }
}

extension LayoutNode: Codable {
    init(from decoder: Decoder) throws {
        let dto = try decoder.singleValueContainer().decode(LayoutNodeDTO.self)
        try self.init(fromDTO: dto, codingPath: decoder.codingPath)
    }

    /// Build a node from an already-decoded DTO. Shared by `LayoutNode` and
    /// `LayoutTab` (a tab is a node with a `name`).
    init(fromDTO dto: LayoutNodeDTO, codingPath: [CodingKey]) throws {
        if let split = dto.split {
            // Split node: requires both children.
            guard let first = split.first?.node, let second = split.second?.node else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: codingPath,
                    debugDescription: "A `split` node requires both `first` and `second`."
                ))
            }
            self = .split(LayoutBranch(direction: split.direction, ratio: split.ratio, first: first, second: second))
        } else {
            // Leaf node: the pane fields apply directly (a bare `{}` is a plain
            // shell).
            self = .pane(LayoutPane(cwd: dto.cwd, run: dto.run, shell: dto.shell))
        }
    }

    func encode(to encoder: Encoder) throws {
        try dto(name: nil).encode(to: encoder)
    }

    /// The DTO wire form, optionally carrying a tab-level `name`.
    func dto(name: String?) -> LayoutNodeDTO {
        switch self {
        case let .pane(p):
            LayoutNodeDTO(name: name, cwd: p.cwd, run: p.run, shell: p.shell)
        case let .split(b):
            LayoutNodeDTO(name: name, split: LayoutSplitDTO(
                direction: b.direction,
                ratio: b.ratio,
                first: LayoutNodeBox(b.first),
                second: LayoutNodeBox(b.second)
            ))
        }
    }
}

struct LayoutPane: Codable, Equatable {
    /// Working directory, project-relative (resolved against the project root).
    /// nil → the project root itself.
    var cwd: String?
    /// Command typed into the pane's shell on launch. nil → plain shell.
    var run: String?
    /// Per-pane shell override. nil → file default, else ghostty-config shell.
    var shell: String?
}

/// In-memory split branch. Not directly Codable — `LayoutNode` encodes/decodes
/// the flat wire form (see `LayoutNodeDTO`).
struct LayoutBranch: Equatable {
    var direction: SplitDirection
    /// Split position of the divider, 0...1. Optional in the file; a missing
    /// value means an even split. Use `resolvedRatio` to read with the default.
    var ratio: Double?
    var first: LayoutNode
    var second: LayoutNode

    /// The divider position with the even-split default applied.
    var resolvedRatio: Double { ratio ?? 0.5 }
}

// MARK: - Parsing

enum LayoutFileError: Error, LocalizedError {
    case notFound(path: String)
    case parse(underlying: Error)

    var errorDescription: String? {
        switch self {
        case let .notFound(path): "No layout file found at \(path)"
        case let .parse(underlying): "The layout file is invalid and was not applied.\n\n\(underlying.localizedDescription)"
        }
    }
}

extension LayoutFile {
    /// Default location of a project's layout file, relative to its root.
    static let relativePath = ".macterm/layout.yaml"

    /// Absolute path to a project's layout file.
    static func url(forProjectRoot root: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent(relativePath)
    }

    /// Whether a project has a layout file on disk.
    static func exists(atProjectRoot root: String) -> Bool {
        FileManager.default.fileExists(atPath: url(forProjectRoot: root).path)
    }

    /// Decode a layout from YAML text.
    static func parse(yaml: String) throws -> LayoutFile {
        do {
            return try YAMLDecoder().decode(LayoutFile.self, from: yaml)
        } catch {
            throw LayoutFileError.parse(underlying: error)
        }
    }

    /// Load and decode a project's layout file from disk.
    static func load(fromProjectRoot root: String) throws -> LayoutFile {
        let url = url(forProjectRoot: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LayoutFileError.notFound(path: url.path)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(yaml: text)
    }

    /// Modeline the YAML Language Server reads to attach our JSON schema, so a
    /// saved `.macterm/layout.yaml` gets completion/validation in editors with
    /// no per-user setup. Hand-authored files can add the same line.
    static let schemaModeline =
        "# yaml-language-server: $schema=https://raw.githubusercontent.com/thdxg/macterm/main/assets/layout.schema.json"

    /// Serialize to YAML text, prefixed with the schema modeline.
    func yaml() throws -> String {
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = false
        return try "\(Self.schemaModeline)\n\(encoder.encode(self))"
    }
}
