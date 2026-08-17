import Foundation
@testable import Macterm
import Testing

/// The tokenizer runs over every rendered diff line, and it scans UTF-8 bytes
/// rather than `Character`s for speed — which puts the burden of proof on
/// these: a byte scanner that miscounts a boundary produces invalid UTF-8, and
/// one that drops a run silently drops CODE.
@MainActor
struct SyntaxHighlightTests {
    /// The property that matters most: joining the tokens must reproduce the
    /// input exactly. Every other test can pass while the view quietly renders
    /// a line with characters missing.
    @Test
    func tokens_always_reproduce_the_line() {
        let lines = [
            #"let x = "hello world" // trailing"#,
            "SELECT * FROM users WHERE id = 42;",
            "  # comentario con acentos: ñ, é, ü",
            "func 𝕗(x: Int) -> Int { x * 2 }",
            "}",
            "        ",
            #"print("emoji 🎉 inside", 1.5e3)"#,
        ]
        for line in lines {
            for language in [SyntaxLanguage.swift, .cLike, .script, .sql, .markup, .plain] {
                let joined = SyntaxHighlighter.tokens(for: line, language: language)
                    .map(\.text)
                    .joined()
                #expect(joined == line, "language \(language) lost or altered text")
            }
        }
    }

    @Test
    func an_empty_line_has_no_tokens() {
        #expect(SyntaxHighlighter.tokens(for: "", language: .swift).isEmpty)
    }

    @Test
    func keywords_are_recognized_per_language() {
        let swift = SyntaxHighlighter.tokens(for: "guard let x = y", language: .swift)
        #expect(swift.first { $0.text == "guard" }?.kind == .keyword)
        // `guard` is not a keyword in SQL, and the tokenizer must not leak one
        // language's table into another.
        let sql = SyntaxHighlighter.tokens(for: "guard let x = y", language: .sql)
        #expect(sql.first { $0.text == "guard" }?.kind == .plain)
    }

    /// SQL is written upper-case by convention while the table is lower-case,
    /// so it is the one language that folds case.
    @Test
    func sql_keywords_match_regardless_of_case() {
        let tokens = SyntaxHighlighter.tokens(for: "SELECT id FROM users", language: .sql)
        #expect(tokens.first { $0.text == "SELECT" }?.kind == .keyword)
        #expect(tokens.first { $0.text == "FROM" }?.kind == .keyword)
    }

    /// A comment swallows the rest of the line — including quotes, which is
    /// exactly what breaks a highlighter that counts quotes first.
    @Test
    func a_comment_swallows_the_rest_of_the_line() throws {
        let tokens = SyntaxHighlighter.tokens(for: #"let a = 1 // it's "fine""#, language: .swift)
        let comment = try #require(tokens.last)
        #expect(comment.kind == .comment)
        #expect(comment.text == #"// it's "fine""#)
    }

    @Test
    func comment_markers_differ_by_language() {
        #expect(SyntaxHighlighter.tokens(for: "-- comment", language: .sql).first?.kind == .comment)
        // In Swift `--` is an operator, not a comment opener.
        #expect(SyntaxHighlighter.tokens(for: "-- comment", language: .swift).first?.kind != .comment)
        #expect(SyntaxHighlighter.tokens(for: "# comment", language: .script).first?.kind == .comment)
    }

    @Test
    func a_string_keeps_its_escaped_quote() throws {
        let tokens = SyntaxHighlighter.tokens(for: #"x = "a\"b" + y"#, language: .cLike)
        let string = try #require(tokens.first { $0.kind == .string })
        #expect(string.text == #""a\"b""#)
    }

    /// Diffs cut lines wherever the hunk ends, so an unterminated quote is
    /// routine input, not a malformed one.
    @Test
    func an_unterminated_string_runs_to_end_of_line() throws {
        let tokens = SyntaxHighlighter.tokens(for: #"let s = "开始 unterminated"#, language: .swift)
        let string = try #require(tokens.first { $0.kind == .string })
        #expect(string.text == #""开始 unterminated"#)
    }

    @Test
    func numbers_are_tokenized_but_not_inside_identifiers() {
        let tokens = SyntaxHighlighter.tokens(for: "let utf8Data2 = 0xFF + 1_000", language: .swift)
        #expect(tokens.contains { $0.text == "0xFF" && $0.kind == .number })
        #expect(tokens.contains { $0.text == "1_000" && $0.kind == .number })
        // The identifier stays whole: no stray `8`/`2` number tokens inside it.
        #expect(tokens.contains { $0.text == "utf8Data2" && $0.kind == .plain })
    }

    /// Multi-byte characters must never be split across two tokens — that is
    /// what would emit invalid UTF-8 from a byte-level scanner.
    @Test
    func multibyte_identifiers_survive_intact() {
        let tokens = SyntaxHighlighter.tokens(for: "let año = 1", language: .swift)
        #expect(tokens.contains { $0.text == "año" })
    }
}
