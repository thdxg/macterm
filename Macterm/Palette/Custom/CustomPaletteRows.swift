import Foundation

/// A listing's row, resolved to what the palette draws and passes on —
/// strings only, so a listing parsed off the main actor crosses back
/// without carrying `JSONSerialization`'s untyped tree.
struct CustomPaletteRow: Equatable {
    let title: String
    let subtitle: String?
    let icon: String?
    /// What the search matches against.
    let match: [String]
    /// Values this row adds to the environment below it.
    let exports: [String: String]
    /// The action's operand resolved against the row (a `copy:` or `open:`
    /// path); nil for `run` and `enter`.
    let operand: String?
    /// The same for the listing's `alt:` action.
    var altOperand: String?
}

/// Turns a listing command's output into rows: pure, so every shape and
/// every failure is a unit test.
enum CustomPaletteRows {
    enum Failure: Error, Equatable {
        case notJSON(String)
        case rowsNotFound(path: String)
        case rowsNotAnArray(path: String)
        case plainOutputWithRowsPath(path: String)
    }

    static func parse(output: String, listing: CustomPalette.Listing) throws -> [CustomPaletteRow] {
        let values = try rowValues(output: output, rowsPath: listing.rowsPath)
        return values.compactMap { value in
            guard let title = resolve(listing.title, in: value), !title.isEmpty else { return nil }
            let operand: String? = switch listing.outcome {
            case let .perform(action): actionOperand(action, in: value)
            case .enter: nil
            }
            return CustomPaletteRow(
                title: title,
                subtitle: listing.subtitle.flatMap { resolve($0, in: value) }.flatMap { $0.isEmpty ? nil : $0 },
                icon: listing.icon.flatMap { resolve($0, in: value) },
                match: listing.match.compactMap { resolve($0, in: value) },
                exports: listing.exports.compactMapValues { resolve($0, in: value) },
                operand: operand,
                altOperand: listing.alt.flatMap { actionOperand($0.action, in: value) }
            )
        }
    }

    /// A `copy:` or `open:` action's text resolved against the row; nil for `run`.
    static func actionOperand(_ action: CustomPaletteAction, in row: Any) -> String? {
        switch action {
        case let .copy(path),
             let .open(path): resolve(path, in: row)
        case .run: nil
        }
    }

    /// The row values: a JSON array, newline-delimited JSON objects, an
    /// object holding the array at `rowsPath`, or — when the output doesn't
    /// start like JSON — plain lines, one row each. Output that merely
    /// starts with a bracket is plain lines too when no `rows:` asks for
    /// JSON and the bracket is followed by what no JSON value starts with —
    /// a log prefix like `[INFO]`; broken or truncated JSON stays "isn't
    /// JSON".
    static func rowValues(output: String, rowsPath: String?) throws -> [Any] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return [] }
        let plainLines = {
            trimmed.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        guard first == "[" || first == "{" else {
            if let rowsPath { throw Failure.plainOutputWithRowsPath(path: rowsPath) }
            return plainLines()
        }
        if rowsPath == nil, first == "[",
           let next = trimmed.dropFirst().first(where: { !$0.isWhitespace }),
           !"\"-0123456789[{]tfn".contains(next)
        {
            return plainLines()
        }
        let top: Any
        if let whole = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]) {
            top = whole
        } else {
            // Newline-delimited objects (`kubectl get -o json | jq -c '.items[]'`).
            var objects: [Any] = []
            for line in trimmed.split(whereSeparator: \.isNewline) {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                do {
                    try objects.append(JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]))
                } catch {
                    throw Failure.notJSON(error.localizedDescription)
                }
            }
            top = objects
        }
        guard let rowsPath, rowsPath != "." else {
            if let array = top as? [Any] { return array }
            return [top]
        }
        guard let found = value(at: rowsPath, in: top) else { throw Failure.rowsNotFound(path: rowsPath) }
        guard let array = found as? [Any] else { throw Failure.rowsNotAnArray(path: rowsPath) }
        return array
    }

    /// `field` resolved against `row`: a path when it starts with `.`, the
    /// text itself otherwise. nil when the path finds nothing scalar.
    static func resolve(_ field: String, in row: Any) -> String? {
        guard field.hasPrefix(".") else { return field }
        return value(at: field, in: row).flatMap(scalarText)
    }

    /// The value at a dotted path — `.a.b`, `.items[0].name`, `.` for the
    /// value itself — or nil where the path leaves the tree.
    static func value(at path: String, in root: Any) -> Any? {
        var current: Any? = root
        for component in path.split(separator: ".", omittingEmptySubsequences: true) {
            var key = Substring(component)
            var indices: [Int] = []
            while let open = key.lastIndex(of: "["), key.hasSuffix("]") {
                guard let index = Int(key[key.index(after: open) ..< key.index(before: key.endIndex)]) else { return nil }
                indices.insert(index, at: 0)
                key = key[..<open]
            }
            if !key.isEmpty {
                guard let object = current as? [String: Any] else { return nil }
                current = object[String(key)]
            }
            for index in indices {
                guard let array = current as? [Any], array.indices.contains(index) else { return nil }
                current = array[index]
            }
        }
        return current
    }

    /// A scalar as the palette shows it; nil for objects, arrays and null.
    static func scalarText(_ value: Any) -> String? {
        switch value {
        case let text as String: text
        case let number as NSNumber:
            // JSONSerialization hands booleans back as NSNumber too; the
            // bridged type tells them apart.
            CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue
        default: nil
        }
    }
}
