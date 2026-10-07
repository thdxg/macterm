import Foundation
import Yams

// A custom palette: `~/.config/macterm/palettes/<name>.yaml`, one file per
// palette, a graph of named NODES. A node is either a static menu (`items:`)
// or a listing (`list:`, a command whose output becomes rows). Every row
// either enters another node (`enter:`) or performs an action (`action:`),
// and may `export:` values that ride down the stack as environment
// variables into every command below it — never substituted into shell
// grammar, so nothing a command prints is ever quoted into another command.
//
//     name: Kubernetes
//     icon: shippingbox
//     root: menu
//     nodes:
//       menu:
//         items:
//           - { title: Namespaces, enter: namespaces }
//           - { title: Pods, enter: pods }
//       namespaces:
//         list: kubectl get ns -o json
//         rows: .items
//         title: .metadata.name
//         export: { NAMESPACE: .metadata.name }
//         enter: namespace-menu
//       namespace-menu:
//         items:
//           - { title: Pods, enter: pods }
//       pods:
//         list: kubectl get pods ${NAMESPACE:+-n "$NAMESPACE"} ${NAMESPACE:--A} -o json
//         rows: .items
//         title: .metadata.name
//         subtitle: .status.phase
//         match: [.metadata.name, .metadata.namespace, .metadata.labels.app]
//         export: { POD: .metadata.name, NAMESPACE: .metadata.namespace }
//         action: { run: kubectl logs -f -n "$NAMESPACE" "$POD", in: split }
//
// Commands run in the user's login shell (`$SHELL -l -c`), so they are
// written in that shell's syntax and see its PATH. A listing's output is
// JSON (an array, newline-delimited objects, or an object with the array at
// `rows:`) or plain lines, one row each. In a listing node, a field whose
// value starts with `.` is a path into the row (`.` is the row itself);
// anything else is literal. In a static item every value is literal.

/// The file as written. `Codable` for Yams; `CustomPalette.init(file:id:)`
/// validates it into the model the scope runs.
struct CustomPaletteFile: Codable, Equatable {
    var name: String
    var icon: String?
    var description: String?
    var root: String?
    var nodes: [String: Node]

    struct Node: Codable, Equatable {
        var placeholder: String?
        /// A static menu's rows.
        var items: [Item]?
        /// A listing's command.
        var list: String?
        /// Path to the array of rows inside the command's JSON output.
        var rows: String?
        var title: String?
        var subtitle: String?
        var icon: String?
        var match: [String]?
        var export: [String: String]?
        var enter: String?
        var action: Action?
    }

    struct Item: Codable, Equatable {
        var title: String
        var subtitle: String?
        var icon: String?
        var export: [String: String]?
        var enter: String?
        var action: Action?
    }

    struct Action: Codable, Equatable {
        var run: String?
        /// Where `run` runs: `tab` (default) or `split`.
        var `in`: String?
        var copy: String?
        var open: String?
    }

    static func parse(yaml: String) throws -> CustomPaletteFile {
        do {
            return try YAMLDecoder().decode(CustomPaletteFile.self, from: yaml)
        } catch {
            throw CustomPaletteError.parse(underlying: error)
        }
    }

    /// What a file says it is, read leniently — so a file that fails
    /// validation still has its name and glyph on its row, and the error
    /// waits until the row is entered. nil when the YAML doesn't parse.
    static func parseHeader(yaml: String) -> CustomPaletteHeader? {
        try? YAMLDecoder().decode(CustomPaletteHeader.self, from: yaml)
    }
}

struct CustomPaletteHeader: Codable, Equatable {
    var name: String?
    var icon: String?
    var description: String?
}

enum CustomPaletteError: Error, LocalizedError, Equatable {
    case parse(underlying: Error)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .parse(underlying): underlying.localizedDescription
        case let .invalid(message): message
        }
    }

    static func == (lhs: CustomPaletteError, rhs: CustomPaletteError) -> Bool {
        lhs.errorDescription == rhs.errorDescription
    }
}

/// Where a `run` action's command runs.
enum CustomPaletteRunTarget: String, Equatable {
    case tab
    case split
}

/// A validated action: exactly one thing to do.
enum CustomPaletteAction: Equatable {
    case run(command: String, in: CustomPaletteRunTarget)
    case copy(String)
    case open(String)

    init(_ action: CustomPaletteFile.Action, at place: String) throws {
        let ops = [action.run != nil, action.copy != nil, action.open != nil].filter(\.self).count
        guard ops == 1 else {
            throw CustomPaletteError.invalid("\(place): action needs exactly one of run:, copy:, open:")
        }
        if let run = action.run {
            let target: CustomPaletteRunTarget
            switch action.in {
            case nil: target = .tab
            case let raw?:
                guard let parsed = CustomPaletteRunTarget(rawValue: raw) else {
                    throw CustomPaletteError.invalid("\(place): in: must be tab or split, not \(raw)")
                }
                target = parsed
            }
            self = .run(command: run, in: target)
        } else if let copy = action.copy {
            self = .copy(copy)
        } else {
            self = .open(action.open ?? "")
        }
    }
}

/// What a row does when picked.
enum CustomPaletteOutcome: Equatable {
    case enter(node: String)
    case perform(CustomPaletteAction)
}

/// A validated palette: every `enter:` names a node, every node is a menu
/// or a listing, every row has an outcome.
struct CustomPalette: Equatable, Identifiable {
    /// The file's stem — stable for the user, so bindings and the Settings
    /// switch key on it.
    let id: String
    let name: String
    let icon: String
    let description: String?
    let root: String
    let nodes: [String: Node]

    static let defaultIcon = "square.grid.2x2"

    struct Node: Equatable {
        let placeholder: String?
        let kind: Kind
        /// The glyph every row shows unless the row names its own.
        let icon: String?

        enum Kind: Equatable {
            case menu([Item])
            case listing(Listing)
        }
    }

    struct Item: Equatable {
        let title: String
        let subtitle: String?
        let icon: String?
        let exports: [String: String]
        let outcome: CustomPaletteOutcome
    }

    /// A listing node's recipe: the command and how its rows become items.
    struct Listing: Equatable {
        let command: String
        /// Path to the array of rows inside an object; nil means the output
        /// is the rows (an array, NDJSON or plain lines).
        let rowsPath: String?
        let title: String
        let subtitle: String?
        let icon: String?
        /// Fields searched; defaults to the title and subtitle.
        let match: [String]
        let exports: [String: String]
        let outcome: CustomPaletteOutcome
    }

    init(file: CustomPaletteFile, id: String) throws {
        self.id = id
        name = file.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw CustomPaletteError.invalid("name: must not be empty") }
        icon = file.icon ?? Self.defaultIcon
        description = file.description
        guard !file.nodes.isEmpty else { throw CustomPaletteError.invalid("nodes: must name at least one node") }
        let root = file.root ?? (file.nodes["root"] != nil ? "root" : "")
        guard file.nodes[root] != nil else {
            throw CustomPaletteError.invalid(
                file.root == nil ? "root: names no node (add a node called root, or set root:)" : "root: no node named \(root)"
            )
        }
        self.root = root

        var nodes: [String: Node] = [:]
        for (name, node) in file.nodes {
            nodes[name] = try Self.validate(node, named: name, nodeNames: Set(file.nodes.keys))
        }
        self.nodes = nodes
    }

    private static func validate(_ node: CustomPaletteFile.Node, named name: String, nodeNames: Set<String>) throws -> Node {
        func outcome(enter: String?, action: CustomPaletteFile.Action?, at place: String) throws -> CustomPaletteOutcome {
            switch (enter, action) {
            case let (enter?, nil):
                guard nodeNames.contains(enter) else { throw CustomPaletteError.invalid("\(place): enter: no node named \(enter)") }
                return .enter(node: enter)
            case let (nil, action?):
                return try .perform(CustomPaletteAction(action, at: place))
            case (nil, nil):
                throw CustomPaletteError.invalid("\(place): needs enter: or action:")
            case (.some, .some):
                throw CustomPaletteError.invalid("\(place): has both enter: and action:; pick one")
            }
        }

        switch (node.items, node.list) {
        case let (items?, nil):
            for key in ["rows", "title", "subtitle", "match", "export"] where node.hasListingField(key) {
                throw CustomPaletteError.invalid("\(name): \(key): belongs to a list: node, not a menu")
            }
            if node.enter != nil || node.action != nil {
                throw CustomPaletteError.invalid("\(name): enter:/action: go on each item of a menu")
            }
            let built = try items.enumerated().map { index, item in
                try Item(
                    title: item.title,
                    subtitle: item.subtitle,
                    icon: item.icon,
                    exports: item.export ?? [:],
                    outcome: outcome(enter: item.enter, action: item.action, at: "\(name) item \(index + 1) (\(item.title))")
                )
            }
            return Node(placeholder: node.placeholder, kind: .menu(built), icon: node.icon)
        case let (nil, command?):
            let title = node.title ?? "."
            let match = node.match ?? [title, node.subtitle].compactMap(\.self)
            let listing = try Listing(
                command: command,
                rowsPath: node.rows,
                title: title,
                subtitle: node.subtitle,
                icon: node.icon,
                match: match,
                exports: node.export ?? [:],
                outcome: outcome(enter: node.enter, action: node.action, at: name)
            )
            return Node(placeholder: node.placeholder, kind: .listing(listing), icon: node.icon)
        case (nil, nil):
            throw CustomPaletteError.invalid("\(name): needs items: (a menu) or list: (a command)")
        case (.some, .some):
            throw CustomPaletteError.invalid("\(name): has both items: and list:; a node is one or the other")
        }
    }
}

private extension CustomPaletteFile.Node {
    func hasListingField(_ key: String) -> Bool {
        switch key {
        case "rows": rows != nil
        case "title": title != nil
        case "subtitle": subtitle != nil
        case "match": match != nil
        case "export": export != nil
        default: false
        }
    }
}
