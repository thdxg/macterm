import Foundation
@testable import Macterm
import Testing

@MainActor
struct PaletteEngineTests {
    // MARK: - fuzzyScore

    @Test
    func fuzzy_empty_query_scores_zero() {
        #expect(fuzzyScore(query: "", target: "anything") == 0)
    }

    @Test
    func fuzzy_prefix_match_scores_zero() {
        #expect(fuzzyScore(query: "git", target: "git status") == 0)
    }

    @Test
    func fuzzy_substring_match_scores_above_five() throws {
        let score = fuzzyScore(query: "stat", target: "git status")
        #expect(score != nil)
        #expect(try #require(score) >= 5)
    }

    @Test
    func fuzzy_subsequence_match_scores_high() throws {
        let score = fuzzyScore(query: "gs", target: "git status")
        #expect(score != nil)
        #expect(try #require(score) >= 40)
    }

    @Test
    func fuzzy_no_match_returns_nil() {
        #expect(fuzzyScore(query: "xyz", target: "git status") == nil)
    }

    @Test
    func fuzzy_prefer_earlier_substring_hit() throws {
        let early = try #require(fuzzyScore(query: "stat", target: "status bar"))
        let late = try #require(fuzzyScore(query: "stat", target: "git status"))
        #expect(early < late)
    }

    // MARK: - Engine + fake source

    /// Test-only source that returns items parameterized by a static list.
    private struct FakeSource: PaletteSource {
        let titles: [String]
        let category: String?
        let emptyStateTitles: [String]?

        func items(query: String, context _: PaletteContext) -> [PaletteItem] {
            titles.compactMap { title in
                guard let score = fuzzyScore(query: query, target: title) else { return nil }
                return PaletteItem(
                    title: title,
                    category: category,
                    score: score,
                    action: {}
                )
            }
        }

        func emptyItems(context _: PaletteContext) -> [PaletteItem]? {
            emptyStateTitles.map { titles in
                titles.map { PaletteItem(title: $0, category: category, action: {}) }
            }
        }
    }

    /// PaletteContext wants a real AppState + ProjectStore; supply minimal stubs.
    private func makeContext() -> PaletteContext {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-tests-\(UUID().uuidString).json")
        let state = AppState(workspaceStore: WorkspaceStore(fileURL: tmp))
        return PaletteContext(appState: state, projectStore: ProjectStore())
    }

    @Test
    func empty_query_returns_source_empty_sections() {
        let ctx = makeContext()
        let engine = PaletteEngine(
            sources: [
                FakeSource(titles: [], category: "Recent", emptyStateTitles: ["Alpha", "Beta"]),
            ],
            context: ctx,
            pathSource: nil
        )
        let result = engine.search("")
        #expect(result.count == 1)
        #expect(result[0].header == "Recent")
        #expect(result[0].items.map(\.title) == ["Alpha", "Beta"])
    }

    @Test
    func empty_query_skips_sources_that_return_no_empty_items() {
        let ctx = makeContext()
        let engine = PaletteEngine(
            sources: [
                FakeSource(titles: [], category: "A", emptyStateTitles: nil),
                FakeSource(titles: [], category: "B", emptyStateTitles: ["x"]),
            ],
            context: ctx,
            pathSource: nil
        )
        let result = engine.search("")
        #expect(result.count == 1)
        #expect(result[0].header == "B")
    }

    @Test
    func active_query_merges_sources_and_sorts_by_score() {
        let ctx = makeContext()
        let engine = PaletteEngine(
            sources: [
                FakeSource(titles: ["gitlab"], category: "Source A", emptyStateTitles: nil),
                FakeSource(titles: ["git status"], category: "Source B", emptyStateTitles: nil),
            ],
            context: ctx,
            pathSource: nil
        )
        // Both are prefix matches ("git"), so both score 0. Sort must be stable by score.
        let result = engine.search("git")
        #expect(result.count == 1)
        #expect(result[0].header == nil) // merged section has no header
        #expect(result[0].items.count == 2)
    }

    @Test
    func active_query_ranks_prefix_above_substring() {
        let ctx = makeContext()
        let engine = PaletteEngine(
            sources: [
                FakeSource(titles: ["stat", "git status"], category: "x", emptyStateTitles: nil),
            ],
            context: ctx,
            pathSource: nil
        )
        let result = engine.search("stat")
        #expect(result[0].items.map(\.title) == ["stat", "git status"])
    }

    @Test
    func path_query_uses_path_source_only() {
        let ctx = makeContext()
        let engine = PaletteEngine(
            sources: [
                FakeSource(titles: ["should not appear"], category: "x", emptyStateTitles: nil),
            ],
            context: ctx,
            pathSource: FakeSource(titles: ["/Users/me/dev"], category: "Path", emptyStateTitles: nil)
        )
        let result = engine.search("/Users")
        #expect(result.count == 1)
        #expect(result[0].items.map(\.title) == ["/Users/me/dev"])
    }

    @Test
    func tilde_query_uses_path_source() {
        let ctx = makeContext()
        let engine = PaletteEngine(
            sources: [],
            context: ctx,
            pathSource: FakeSource(titles: ["~/dev"], category: nil, emptyStateTitles: nil)
        )
        let result = engine.search("~/dev")
        #expect(result.count == 1)
        #expect(result[0].items.map(\.title) == ["~/dev"])
    }

    @Test
    func path_query_with_empty_path_source_returns_empty() {
        let ctx = makeContext()
        let engine = PaletteEngine(
            sources: [FakeSource(titles: ["git"], category: nil, emptyStateTitles: nil)],
            context: ctx,
            pathSource: FakeSource(titles: [], category: nil, emptyStateTitles: nil)
        )
        #expect(engine.search("/nope").isEmpty)
    }

    @Test
    func no_matches_returns_empty_sections() {
        let ctx = makeContext()
        let engine = PaletteEngine(
            sources: [FakeSource(titles: ["git"], category: "x", emptyStateTitles: nil)],
            context: ctx,
            pathSource: nil
        )
        #expect(engine.search("zzz").isEmpty)
    }

    @Test
    func empty_state_groups_items_by_category() {
        let ctx = makeContext()
        let engine = PaletteEngine(
            sources: [
                FakeSource(titles: [], category: "A", emptyStateTitles: ["a1", "a2"]),
                FakeSource(titles: [], category: "B", emptyStateTitles: ["b1"]),
            ],
            context: ctx,
            pathSource: nil
        )
        let result = engine.search("")
        #expect(result.count == 2)
        #expect(result[0].header == "A")
        #expect(result[0].items.count == 2)
        #expect(result[1].header == "B")
        #expect(result[1].items.count == 1)
    }
}
