import Foundation
import Yams

// A custom palette: `~/.config/macterm/palettes/<name>.yaml`, one file per
// palette, a graph of named NODES. A node has static rows (`items:`), a
// listing (`list:`, a command whose output becomes rows), or both — the
// items first, then the listing's rows. Every row either enters another node
// (`enter:`) or performs an action (`action:`), may name a second action
// for ⌥↩ (`alt:`), and may `export:` values that ride down the stack as environment
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
//         list: if [ -n "$NAMESPACE" ]; then set -- -n "$NAMESPACE"; else set -- -A; fi; kubectl get pods "$@" -o json
//         rows: .items
//         title: .metadata.name
//         subtitle: .status.phase
//         match: [.metadata.name, .metadata.namespace, .metadata.labels.app]
//         export: { POD: .metadata.name, NAMESPACE: .metadata.namespace }
//         action: { run: kubectl logs -f -n "$NAMESPACE" "$POD", in: split }
//
// Commands are POSIX sh with errexit, or any interpreter a command names on
// a `#!` first line, the way mise runs a task — the same in every user's
// hands, whatever their login shell. They are started from the login
// shell all the same, so they see the PATH its rc files build
// (`CustomPaletteScript`). `requires:` names the programs the commands need,
// so a listing that fails for want of one says which. A listing's output is
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
    /// Programs the commands need, by name.
    var requires: [String]?
    /// Whether the palette can be used now (`CustomPaletteCondition`).
    var when: Condition?
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
        var alt: Action?
    }

    struct Item: Codable, Equatable {
        var title: String
        var subtitle: String?
        var icon: String?
        var export: [String: String]?
        var enter: String?
        var action: Action?
        var alt: Action?
        /// Whether the row can be picked now (`CustomPaletteCondition`).
        var when: Condition?
    }

    /// `when: { run: <command>, unavailable: <reason> }`.
    struct Condition: Codable, Equatable {
        var run: String
        var unavailable: String?
    }

    struct Action: Codable, Equatable {
        /// What the row's subtitle reads while ⌥ is down — `alt:` only.
        var title: String?
        var run: String?
        /// Where `run` runs: `tab` (default) or `split`.
        var `in`: String?
        var copy: String?
        var open: String?
    }

    static func parse(yaml: String) throws -> CustomPaletteFile {
        let file: CustomPaletteFile
        do {
            file = try YAMLDecoder().decode(CustomPaletteFile.self, from: yaml)
        } catch {
            throw CustomPaletteError.parse(underlying: error)
        }
        if let unknown = unknownKey(yaml: yaml) { throw CustomPaletteError.invalid(unknown) }
        return file
    }

    /// The keys each level of a file may have — the schema's `properties`,
    /// which `CustomPaletteFileTests` holds these to.
    static let fileKeys: Set<String> = ["name", "icon", "description", "requires", "when", "root", "nodes"]
    static let nodeKeys: Set<String> = [
        "placeholder", "items", "list", "rows", "title", "subtitle", "icon", "match", "export", "enter", "action", "alt",
    ]
    static let itemKeys: Set<String> = ["title", "subtitle", "icon", "export", "enter", "action", "alt", "when"]
    static let conditionKeys: Set<String> = ["run", "unavailable"]
    static let actionKeys: Set<String> = ["title", "run", "in", "copy", "open"]

    /// The first key the file has that no level takes, named where it is
    /// (`pods: mathc: no such key`), as every other mistake is. The decoder
    /// drops a key it doesn't know, so without this a misspelled optional
    /// key (`subtitel:`) would silently do nothing.
    static func unknownKey(yaml: String) -> String? {
        // The decoder's own resolver (merge keys only), so a node named
        // `404:` or `on:` stays a string key here as it does there, rather
        // than turning the whole `nodes:` map into one this can't read.
        guard let root = (try? Yams.load(yaml: yaml, Resolver.basic.appending(.merge))) as? [String: Any] else { return nil }
        func stray(_ dict: [String: Any], _ allowed: Set<String>) -> String? {
            dict.keys.filter { !allowed.contains($0) && $0 != "<<" }.min()
        }
        func action(_ value: Any?, at place: String) -> String? {
            guard let dict = value as? [String: Any], let key = stray(dict, actionKeys) else { return nil }
            return "\(place): \(key): no such key"
        }
        func condition(_ value: Any?, at place: String) -> String? {
            guard let dict = value as? [String: Any], let key = stray(dict, conditionKeys) else { return nil }
            return "\(place): \(key): no such key"
        }
        if let key = stray(root, fileKeys) { return "\(key): no such key" }
        if let problem = condition(root["when"], at: "when") { return problem }
        let nodes = root["nodes"] as? [String: Any] ?? [:]
        for name in nodes.keys.sorted() {
            guard let node = nodes[name] as? [String: Any] else { continue }
            if let key = stray(node, nodeKeys) { return "\(name): \(key): no such key" }
            if let problem = action(node["action"], at: "\(name): action") ?? action(node["alt"], at: "\(name): alt") {
                return problem
            }
            for (index, value) in (node["items"] as? [Any] ?? []).enumerated() {
                guard let item = value as? [String: Any] else { continue }
                let place = "\(name) item \(index + 1) (\(item["title"].map { "\($0)" } ?? ""))"
                if let key = stray(item, itemKeys) { return "\(place): \(key): no such key" }
                if let problem = condition(item["when"], at: "\(place): when") { return problem }
                if let problem = action(item["action"], at: "\(place): action") ?? action(item["alt"], at: "\(place): alt") {
                    return problem
                }
            }
        }
        return nil
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
        } else {
            // `in:` says where a command runs; a copy or an open has none.
            if let raw = action.in {
                throw CustomPaletteError.invalid("\(place): in: \(raw) goes with run:, not copy: or open:")
            }
            self = if let copy = action.copy { .copy(copy) } else { .open(action.open ?? "") }
        }
    }
}

/// `when:` — whether a palette or one of its items can be used now: a
/// command (POSIX sh, or a `#!` script, as every palette command is) that
/// exits 0 when it can, and the reason shown on the muted row when it
/// can't. Checked fresh each time the row is shown, in the background —
/// the row is usable until the check says otherwise — and never
/// remembered past that open (`CustomPaletteConditions`).
struct CustomPaletteCondition: Equatable {
    let command: String
    let reason: String

    static let defaultReason = "Unavailable"

    init(command: String, reason: String) {
        self.command = command
        self.reason = reason
    }

    init?(_ condition: CustomPaletteFile.Condition?, at place: String) throws {
        guard let condition else { return nil }
        guard !condition.run.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CustomPaletteError.invalid("\(place): run: must not be empty")
        }
        command = condition.run
        let reason = condition.unavailable?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.reason = reason.isEmpty ? Self.defaultReason : reason
    }
}

/// An `export:`'s variable names: ones `sh` can read (`[A-Za-z_][A-Za-z0-9_]*`),
/// and none Macterm sets itself — those would be silently overwritten.
enum CustomPaletteExports {
    static let reserved: Set<String> = [
        CustomPaletteEnvironment.projectDirectoryKey,
        CustomPaletteEnvironment.projectNameKey,
        CustomPaletteScript.commandVariable,
        CustomPaletteRequirements.variable,
        MactermExtension.directoryVariable,
    ]

    static func validate(_ exports: [String: String]?, at place: String) throws {
        for name in (exports ?? [:]).keys.sorted() {
            let scalars = Array(name.unicodeScalars)
            let isName = scalars.first.map { $0 == "_" || ($0.isASCII && CharacterSet.letters.contains($0)) } == true
                && scalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
            guard isName else {
                throw CustomPaletteError.invalid("\(place): export: \(name) isn't a variable name sh can read")
            }
            guard !reserved.contains(name) else {
                throw CustomPaletteError.invalid("\(place): export: \(name) is set by Macterm; pick another name")
            }
        }
    }
}

/// What a row does when picked.
enum CustomPaletteOutcome: Equatable {
    case enter(node: String)
    case perform(CustomPaletteAction)
}

/// A row's ⌥ action: what ⌥↩ or ⌥-click does instead, and the line its
/// row reads while ⌥ is down.
struct CustomPaletteAlt: Equatable {
    let title: String
    let action: CustomPaletteAction

    init(_ alt: CustomPaletteFile.Action, at place: String) throws {
        action = try CustomPaletteAction(alt, at: "\(place): alt")
        title = alt.title ?? Self.defaultTitle(action)
    }

    static func defaultTitle(_ action: CustomPaletteAction) -> String {
        switch action {
        case .run(_, .tab): "Run in a New Tab"
        case .run(_, .split): "Run in a Split"
        case .copy: "Copy"
        case .open: "Open"
        }
    }
}

/// A validated palette: every `enter:` names a node, every node has items,
/// a listing or both, every row has an outcome.
struct CustomPalette: Equatable, Identifiable {
    /// The file's stem — stable for the user, so bindings and the Settings
    /// switch key on it.
    let id: String
    let name: String
    let icon: String
    let description: String?
    let requires: [String]
    /// Checked each time the palette's row is shown and when it opens.
    let condition: CustomPaletteCondition?
    let root: String
    let nodes: [String: Node]

    static let defaultIcon = "square.grid.2x2"

    struct Node: Equatable {
        let placeholder: String?
        /// The rows written out, shown before the listing's.
        let items: [Item]
        /// The command whose output adds rows after the items, if any.
        let listing: Listing?
        /// The glyph every row shows unless the row names its own.
        let icon: String?
    }

    struct Item: Equatable {
        let title: String
        let subtitle: String?
        let icon: String?
        let exports: [String: String]
        let outcome: CustomPaletteOutcome
        var alt: CustomPaletteAlt?
        /// Checked each time the item's screen opens.
        var condition: CustomPaletteCondition?
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
        var alt: CustomPaletteAlt?
    }

    init(file: CustomPaletteFile, id: String) throws {
        self.id = id
        name = file.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw CustomPaletteError.invalid("name: must not be empty") }
        icon = file.icon ?? Self.defaultIcon
        description = file.description
        requires = file.requires ?? []
        for program in requires where !CustomPaletteRequirements.isProgramName(program) {
            throw CustomPaletteError.invalid("requires: \(program) isn't a program name")
        }
        condition = try CustomPaletteCondition(file.when, at: "when")
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

        if node.items == nil, node.list == nil {
            throw CustomPaletteError.invalid("\(name): needs items: (rows written out) or list: (a command)")
        }
        func alt(_ alt: CustomPaletteFile.Action?, at place: String) throws -> CustomPaletteAlt? {
            try alt.map { try CustomPaletteAlt($0, at: place) }
        }
        let items = try (node.items ?? []).enumerated().map { index, item in
            let place = "\(name) item \(index + 1) (\(item.title))"
            if let action = item.action, action.title != nil {
                throw CustomPaletteError.invalid("\(place): title: goes on alt:, not action:")
            }
            try CustomPaletteExports.validate(item.export, at: place)
            return try Item(
                title: item.title,
                subtitle: item.subtitle,
                icon: item.icon,
                exports: item.export ?? [:],
                outcome: outcome(enter: item.enter, action: item.action, at: place),
                alt: alt(item.alt, at: place),
                condition: CustomPaletteCondition(item.when, at: "\(place): when")
            )
        }
        guard let command = node.list else {
            for key in ["rows", "title", "subtitle", "match", "export"] where node.hasListingField(key) {
                throw CustomPaletteError.invalid("\(name): \(key): belongs to a list: node")
            }
            if node.enter != nil || node.action != nil || node.alt != nil {
                throw CustomPaletteError.invalid("\(name): enter:/action:/alt: go on each item, or with a list:")
            }
            return Node(placeholder: node.placeholder, items: items, listing: nil, icon: node.icon)
        }
        if let action = node.action, action.title != nil {
            throw CustomPaletteError.invalid("\(name): title: goes on alt:, not action:")
        }
        let title = node.title ?? "."
        if node.match?.isEmpty == true {
            throw CustomPaletteError.invalid("\(name): match: needs at least one field, or leave it out")
        }
        let match = node.match ?? [title, node.subtitle].compactMap(\.self)
        try CustomPaletteExports.validate(node.export, at: name)
        let listing = try Listing(
            command: command,
            rowsPath: node.rows,
            title: title,
            subtitle: node.subtitle,
            icon: node.icon,
            match: match,
            exports: node.export ?? [:],
            outcome: outcome(enter: node.enter, action: node.action, at: name),
            alt: alt(node.alt, at: name)
        )
        return Node(placeholder: node.placeholder, items: items, listing: listing, icon: node.icon)
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
