import Foundation
@testable import Macterm
import Testing

/// The one search engine (`Search`, `SearchIndex`): fzf's ranking, pinned on
/// the app's own command titles, plus the machinery that keeps it fast on a
/// long list — top-K, the parallel path, session narrowing — held to the same
/// answers as the plain path.
struct SearchEngineTests {
    private let commands = AppCommand.allCases.map(\.title)

    private func ranked(_ query: String, _ titles: [String]) -> [String] {
        SearchIndex(titles.map { [$0] }).search(SearchQuery(query)).map { titles[$0.index] }
    }

    // MARK: - Ranking

    @Test
    func initials_find_the_command_they_start() {
        #expect(ranked("sr", commands).first == "Split Right")
        #expect(ranked("nt", commands).first == "New Tab")
        #expect(ranked("tqt", commands).first == "Toggle Quick Terminal")
    }

    @Test
    func words_match_in_any_order_and_all_must_match() {
        #expect(ranked("split right", commands) == ["Split Right"])
        #expect(ranked("right split", commands) == ["Split Right"])
        #expect(ranked("split nowhere", commands).isEmpty)
    }

    @Test
    func a_word_start_beats_the_same_letters_inside_a_word() {
        #expect(ranked("close", commands).prefix(3).allSatisfy { $0.hasPrefix("Close") })
        #expect(ranked("stat", ["git status", "stat"]) == ["stat", "git status"])
        #expect(ranked("gs", ["ages", "gitStatus"]).first == "gitStatus", "a camelCase hump is a word start")
        #expect(ranked("cfg", ["src/cfg.swift", "configure"]).first == "src/cfg.swift", "a run beats scattered letters")
    }

    /// fzf's `bonusFor`: anything but whitespace after a space or a
    /// delimiter starts a word — the `.` of `.env`, the `-` of `-f`.
    @Test
    func punctuation_after_a_space_starts_a_word_as_in_fzf() {
        #expect(ranked(".e", ["config.env", ".env.example"]).first == ".env.example")
        #expect(ranked("-f", ["nix-fmt", "git commit --amend -f"]).first == "git commit --amend -f")
    }

    /// A combining accent (a decomposed `é`, as file names and command
    /// output often arrive) folds away like a precomposed one's, and neither
    /// breaks a run nor starts a word.
    @Test
    func a_decomposed_accent_folds_like_a_precomposed_one() {
        #expect(ranked("cafe\u{301}", ["café"]) == ["café"])
        #expect(ranked("café", ["cafe\u{301}"]) == ["cafe\u{301}"])
        let scratch = SearchScratch()
        let precomposed = SearchIndex.score(SearchQuery("resume"), fields: [SearchText("résumé.pdf")], scratch: scratch)
        let decomposed = SearchIndex.score(SearchQuery("resume"), fields: [SearchText("re\u{301}sume\u{301}.pdf")], scratch: scratch)
        #expect(precomposed != nil && precomposed == decomposed)
        #expect(
            SearchIndex.highlights(SearchQuery("sum"), in: SearchText("re\u{301}sume\u{301}")) == [3, 4, 5],
            "offsets still count the accent's scalar"
        )
    }

    /// `Search.rank` breaks ties as `SearchIndex.rank` does: the shorter
    /// title, then list order.
    @Test
    func a_settings_list_breaks_ties_like_the_index() {
        #expect(Search.rank(["Split Right Pane", "Split Right"], by: "split right") { [$0] } == ["Split Right", "Split Right Pane"])
        #expect(Search.rank(["Zoom Pane", "Next Pane"], by: "pane") { [$0] } == ["Zoom Pane", "Next Pane"])
    }

    @Test
    func case_and_diacritics_fold_and_an_empty_query_matches_everything() {
        #expect(ranked("CAFE", ["Café", "Cake"]) == ["Café"])
        #expect(ranked("strasse", ["Straße"]) == ["Straße"])
        #expect(ranked("", ["b", "a"]) == ["b", "a"], "an empty query keeps list order")
        #expect(ranked("xyz", ["git status"]).isEmpty)
    }

    @Test
    func a_title_match_outranks_the_same_match_in_a_later_field() {
        let index = SearchIndex([["other", "macterm"], ["macterm", "other"]])
        #expect(index.search(SearchQuery("macterm")).map(\.index) == [1, 0])
    }

    // MARK: - Highlights

    @Test
    func highlights_are_scalar_offsets_in_the_title() {
        #expect(Search.match("sr", fields: ["Split Right"])?.highlights == [0, 6])
        #expect(Search.match("spri", fields: ["Split Right"])?.highlights == [0, 1, 6, 7])
        #expect(Search.match("right split", fields: ["Split Right"])?.highlights == [0, 1, 2, 3, 4, 6, 7, 8, 9, 10])
        // `ß` folds to two scalars but is one in the title.
        #expect(Search.match("strasse", fields: ["Straße"])?.highlights == [0, 1, 2, 3, 4, 5])
        #expect(Search.match("sr", fields: ["nope", "Split Right"])?.highlights.isEmpty == true)
    }

    @Test
    func a_highlight_exists_exactly_when_a_score_does() {
        var generator = SeededGenerator(seed: 7)
        let alphabet = Array("abcde /-_X")
        for _ in 0 ..< 500 {
            let text = String((0 ..< Int.random(in: 0 ... 12, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
            let query = String((0 ..< Int.random(in: 1 ... 3, using: &generator)).map { _ in "abcde".randomElement(using: &generator)! })
            let term = SearchTerm(query)
            let prepared = SearchText(text)
            let score = SearchScoring.score(term, in: prepared, scratch: SearchScratch())
            let positions = SearchScoring.positions(term, in: prepared)
            #expect((score == nil) == (positions == nil), "\(query) in \(text)")
            if let positions {
                #expect(positions == positions.sorted() && Set(positions).count == positions.count)
                #expect(positions.map { prepared.scalars[$0] } == term.scalars)
            }
        }
    }

    // MARK: - Long lists

    private func paths(_ count: Int) -> [String] {
        var generator = SeededGenerator(seed: 42)
        let words = ["src", "lib", "main", "test", "view", "model", "search", "palette", "config", "window"]
        return (0 ..< count).map { i in
            (0 ..< Int.random(in: 2 ... 5, using: &generator)).map { _ in words.randomElement(using: &generator)! }
                .joined(separator: "/") + "/file\(i).swift"
        }
    }

    @Test
    func the_parallel_path_finds_what_the_plain_one_does() {
        let list = paths(SearchIndex.parallelThreshold + 1500)
        let index = SearchIndex(list.map { [$0] })
        let query = SearchQuery("src view")
        let parallel = index.search(query)
        let plain = list.indices.compactMap { i in
            SearchIndex.score(query, fields: [SearchText(list[i])], scratch: SearchScratch()).map { SearchMatch(index: i, score: $0) }
        }
        #expect(parallel.count == plain.count)
        #expect(Set(parallel.map(\.index)) == Set(plain.map(\.index)))
        let byIndex = { (matches: [SearchMatch]) in matches.sorted { $0.index < $1.index }.map { [$0.index, Int($0.score)] } }
        #expect(byIndex(parallel) == byIndex(plain), "and scores each the same")
    }

    @Test
    func a_limit_returns_the_head_of_the_full_ranking() {
        let index = SearchIndex(paths(3000).map { [$0] })
        for text in ["m", "src", "pal sea", "file1"] {
            let query = SearchQuery(text)
            #expect(index.search(query, limit: 25) == Array(index.search(query).prefix(25)), "\(text)")
        }
    }

    @Test
    func a_session_answers_every_keystroke_as_a_fresh_search_would() {
        let index = SearchIndex(paths(6000).map { [$0] })
        let session = SearchSession(index: index)
        // Typing, a second word, then backspacing into the first word.
        for text in ["p", "pa", "pal", "pal ", "pal v", "pal vi", "pal v", "pal", "pa", "s", "sr", "src"] {
            #expect(session.search(text, limit: 50) == index.search(SearchQuery(text), limit: 50), "\(text)")
        }
    }

    @Test
    func narrowing_is_only_claimed_when_it_holds() {
        #expect(SearchQuery("pal").narrows(SearchQuery("pa")))
        #expect(SearchQuery("pa v").narrows(SearchQuery("pa")))
        #expect(!SearchQuery("pa").narrows(SearchQuery("pal")))
        #expect(!SearchQuery("xpa").narrows(SearchQuery("pa")))
        // Split into words, the letters may come in any order: `p a` finds
        // `ap`, which `pa` didn't.
        #expect(!SearchQuery("p a").narrows(SearchQuery("pa")))
    }

    // MARK: - Filters and completion

    @Test
    func a_filter_matches_every_word_in_some_field() {
        #expect(Search.matches("split right", in: ["Split Right", "Panes"]))
        #expect(Search.matches("panes right", in: ["Split Right", "Panes"]))
        #expect(!Search.matches("split left", in: ["Split Right", "Panes"]))
        #expect(Search.matches("  ", in: []))
    }

    @Test
    func completion_is_a_folded_prefix() {
        #expect(Search.hasPrefix("Développement", "deve"))
        #expect(!Search.hasPrefix("dev", "develop"))
    }
}

/// A deterministic generator, so a failing case names the same input every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
