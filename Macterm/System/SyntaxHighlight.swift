import Foundation

/// A minimal, language-agnostic tokenizer for the diff viewer.
///
/// Deliberately NOT a parser: a diff line is a FRAGMENT — half a string
/// literal, the middle of a block comment, a line whose context was deleted —
/// so anything that needs a well-formed program would fail on most of its
/// input. This scans one line at a time and gives up gracefully, which is the
/// right trade for coloring: a wrong color costs a glance, a hang costs the
/// window. Per-language config is a keyword list and comment markers, nothing
/// more.
enum SyntaxLanguage {
    case swift
    case cLike
    case script
    case sql
    case markup
    case plain

    /// Pick a language from a path extension. Unknown extensions get `.plain`,
    /// which still colors strings, numbers and comments — the tokens whose
    /// syntax is near-universal — rather than nothing.
    static func forPath(_ path: String) -> SyntaxLanguage {
        switch path.split(separator: ".").last.map(String.init)?.lowercased() ?? "" {
        case "swift": .swift
        case "c",
             "h",
             "cpp",
             "hpp",
             "m",
             "mm",
             "java",
             "kt",
             "kts",
             "cs",
             "go",
             "rs",
             "scala": .cLike
        case "js",
             "jsx",
             "ts",
             "tsx",
             "py",
             "rb",
             "sh",
             "bash",
             "zsh",
             "fish",
             "pl",
             "lua",
             "nu": .script
        case "sql": .sql
        case "html",
             "xml",
             "svg",
             "md",
             "markdown",
             "yml",
             "yaml",
             "json",
             "toml": .markup
        default: .plain
        }
    }

    /// Comment markers as UTF-8 bytes, built once per language. The tokenizer
    /// compares bytes (see `SyntaxHighlighter.tokens`), and these used to be
    /// computed properties returning `[Character]` — rebuilt for EVERY
    /// character of every line, which is what pegged the CPU on a normal diff.
    var commentMarkerBytes: [[UInt8]] {
        switch self {
        case .swift,
             .cLike: Self.slashMarkers
        case .script,
             .plain: Self.scriptMarkers
        case .sql: Self.dashMarkers
        case .markup: Self.markupMarkers
        }
    }

    private static let slashMarkers: [[UInt8]] = [Array("//".utf8)]
    private static let scriptMarkers: [[UInt8]] = [Array("#".utf8), Array("//".utf8)]
    private static let dashMarkers: [[UInt8]] = [Array("--".utf8)]
    private static let markupMarkers: [[UInt8]] = [Array("<!--".utf8)]

    var keywords: Set<String> {
        switch self {
        case .swift: Self.swiftKeywords
        case .cLike: Self.cLikeKeywords
        case .script: Self.scriptKeywords
        case .sql: Self.sqlKeywords
        case .markup,
             .plain: Self.literalKeywords
        }
    }

    private static let swiftKeywords: Set<String> = [
        "actor", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
        "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "for",
        "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let", "nil", "nonisolated",
        "open", "operator", "private", "protocol", "public", "repeat", "return", "self", "static", "struct",
        "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var", "where",
        "while", "some", "any", "final", "lazy", "weak", "unowned", "override", "mutating",
    ]

    private static let cLikeKeywords: Set<String> = [
        "auto", "bool", "break", "case", "catch", "char", "class", "const", "continue", "default", "delete",
        "do", "double", "else", "enum", "extern", "false", "final", "float", "for", "func", "go", "goto",
        "if", "impl", "import", "int", "interface", "let", "long", "map", "match", "mut", "namespace", "new",
        "nil", "null", "package", "private", "protected", "public", "pub", "return", "self", "short",
        "signed", "sizeof", "static", "struct", "switch", "template", "this", "throw", "true", "try", "type",
        "typedef", "union", "unsigned", "use", "using", "var", "void", "while",
    ]

    private static let scriptKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "case", "class", "const", "continue", "def",
        "default", "del", "delete", "do", "elif", "else", "end", "except", "export", "extends", "false",
        "finally", "for", "from", "function", "global", "if", "import", "in", "instanceof", "is", "lambda",
        "let", "new", "nil", "none", "not", "null", "or", "pass", "print", "raise", "return", "self",
        "super", "switch", "then", "this", "throw", "true", "try", "typeof", "undefined", "unless", "until",
        "var", "while", "with", "yield",
    ]

    private static let sqlKeywords: Set<String> = [
        "add", "all", "alter", "and", "any", "array", "as", "asc", "begin", "between", "boolean", "by",
        "cascade", "case", "check", "column", "comment", "commit", "constraint", "create", "default",
        "delete", "desc", "distinct", "drop", "else", "end", "exists", "false", "foreign", "from", "grant",
        "group", "having", "if", "in", "index", "insert", "int", "integer", "into", "is", "join", "key",
        "left", "like", "limit", "not", "null", "on", "or", "order", "primary", "references", "returning",
        "revoke", "right", "rollback", "select", "set", "table", "text", "then", "true", "union", "unique",
        "update", "using", "values", "view", "when", "where", "with",
    ]

    private static let literalKeywords: Set<String> = ["false", "null", "true"]

    /// SQL keywords are conventionally written upper-case and the lists above
    /// are lower-case, so only this language folds case before matching.
    var isCaseInsensitive: Bool { self == .sql }
}

/// One colored run of a line. Runs are contiguous and in order, so joining
/// their text reproduces the input exactly — a property the tests pin, because
/// a tokenizer that silently drops characters would silently drop CODE.
struct SyntaxToken: Equatable {
    enum Kind: Equatable {
        case plain
        case keyword
        case string
        case comment
        case number
    }

    let text: String
    let kind: Kind
}

enum SyntaxHighlighter {
    /// Tokenize one line, scanning UTF-8 BYTES rather than `Character`s.
    ///
    /// That is the whole performance story: Swift's `Character` is a grapheme
    /// cluster, so `Array(line)` allocates and every comparison walks Unicode
    /// tables — profiling a normal diff put `isCommentStart` and `Character.==`
    /// at the top of the sample, burning entire cores. Every token boundary
    /// this recognizes (quotes, comment markers, identifier and digit
    /// boundaries) is ASCII, and any byte ≥ 0x80 is treated as identifier
    /// content, so a multi-byte character can never be split across two
    /// tokens — the slices stay valid UTF-8.
    static func tokens(for line: String, language: SyntaxLanguage) -> [SyntaxToken] {
        guard !line.isEmpty else { return [] }
        // Read the language's tables ONCE. Both are returned by value, so
        // touching them inside the loop copied a 60-element Set (and the
        // marker arrays) for every byte.
        let keywords = language.keywords
        let markers = language.commentMarkerBytes
        let foldsCase = language.isCaseInsensitive
        let bytes = Array(line.utf8)
        var tokens: [SyntaxToken] = []
        var plainStart = 0
        var index = 0

        func flushPlain(upTo end: Int) {
            guard end > plainStart else { return }
            tokens.append(SyntaxToken(text: slice(bytes, plainStart, end), kind: .plain))
        }

        while index < bytes.count {
            let byte = bytes[index]

            // A comment marker swallows the rest of the line, so nothing after
            // it needs scanning — including quotes, which is exactly the case
            // that breaks a naive quote-counting highlighter.
            if isCommentStart(at: index, bytes: bytes, markers: markers) {
                flushPlain(upTo: index)
                tokens.append(SyntaxToken(text: slice(bytes, index, bytes.count), kind: .comment))
                return tokens
            }

            if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") || byte == UInt8(ascii: "`") {
                flushPlain(upTo: index)
                let end = endOfString(from: index, bytes: bytes, quote: byte)
                tokens.append(SyntaxToken(text: slice(bytes, index, end), kind: .string))
                index = end
                plainStart = end
                continue
            }

            // A digit only starts a number when it isn't inside an identifier
            // (`utf8Data2` is one token, not an identifier and a number).
            if isDigit(byte), !isIdentifierByte(index > 0 ? bytes[index - 1] : nil) {
                flushPlain(upTo: index)
                let end = endOfNumber(from: index, bytes: bytes)
                tokens.append(SyntaxToken(text: slice(bytes, index, end), kind: .number))
                index = end
                plainStart = end
                continue
            }

            if isIdentifierStart(byte) {
                flushPlain(upTo: index)
                let end = endOfIdentifier(from: index, bytes: bytes)
                let text = slice(bytes, index, end)
                let lookup = foldsCase ? text.lowercased() : text
                tokens.append(SyntaxToken(text: text, kind: keywords.contains(lookup) ? .keyword : .plain))
                index = end
                plainStart = end
                continue
            }

            index += 1
        }
        flushPlain(upTo: bytes.count)
        return tokens
    }

    // MARK: - Scanners

    private static func slice(_ bytes: [UInt8], _ start: Int, _ end: Int) -> String {
        String(decoding: bytes[start ..< end], as: UTF8.self)
    }

    private static func isCommentStart(at index: Int, bytes: [UInt8], markers: [[UInt8]]) -> Bool {
        for marker in markers where index + marker.count <= bytes.count {
            var matched = true
            for offset in 0 ..< marker.count where bytes[index + offset] != marker[offset] {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    /// Honors backslash escapes so `"a\"b"` stays one token. An unterminated
    /// quote — routine in a diff, which cuts lines wherever the hunk ends —
    /// runs to end of line rather than failing.
    private static func endOfString(from index: Int, bytes: [UInt8], quote: UInt8) -> Int {
        var i = index + 1
        while i < bytes.count {
            let byte = bytes[i]
            i += 1
            if byte == UInt8(ascii: "\\") {
                i += 1
                continue
            }
            if byte == quote { break }
        }
        return min(i, bytes.count)
    }

    private static func endOfNumber(from index: Int, bytes: [UInt8]) -> Int {
        var i = index
        while i < bytes.count, isNumberBody(bytes[i]) {
            i += 1
        }
        return i
    }

    private static func endOfIdentifier(from index: Int, bytes: [UInt8]) -> Int {
        var i = index
        while i < bytes.count, isIdentifierByte(bytes[i]) {
            i += 1
        }
        return i
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
    }

    private static func isNumberBody(_ byte: UInt8) -> Bool {
        isDigit(byte) || isLetter(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_")
    }

    private static func isIdentifierStart(_ byte: UInt8) -> Bool {
        isLetter(byte) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$")
            || byte == UInt8(ascii: "@") || byte >= 0x80
    }

    /// Bytes ≥ 0x80 are the continuation and lead bytes of multi-byte
    /// characters; counting them as identifier content is what keeps a token
    /// from ending mid-character and producing invalid UTF-8.
    private static func isIdentifierByte(_ byte: UInt8?) -> Bool {
        guard let byte else { return false }
        return isLetter(byte) || isDigit(byte) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "$") || byte >= 0x80
    }
}
