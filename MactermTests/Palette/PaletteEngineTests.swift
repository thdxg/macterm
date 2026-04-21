@testable import Macterm
import XCTest

@MainActor
final class PaletteEngineTests: XCTestCase {
    // MARK: - fuzzyScore

    func test_fuzzy_empty_query_scores_zero() {
        XCTAssertEqual(fuzzyScore(query: "", target: "anything"), 0)
    }

    func test_fuzzy_prefix_match_scores_zero() {
        XCTAssertEqual(fuzzyScore(query: "git", target: "git status"), 0)
    }

    func test_fuzzy_substring_match_scores_above_five() throws {
        let score = fuzzyScore(query: "stat", target: "git status")
        XCTAssertNotNil(score)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(score), 5)
    }

    func test_fuzzy_subsequence_match_scores_high() throws {
        let score = fuzzyScore(query: "gs", target: "git status")
        XCTAssertNotNil(score)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(score), 40)
    }

    func test_fuzzy_no_match_returns_nil() {
        XCTAssertNil(fuzzyScore(query: "xyz", target: "git status"))
    }

    func test_fuzzy_prefer_earlier_substring_hit() throws {
        let early = try XCTUnwrap(fuzzyScore(query: "stat", target: "status bar"))
        let late = try XCTUnwrap(fuzzyScore(query: "stat", target: "git status"))
        XCTAssertLessThan(early, late)
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

    func test_empty_query_returns_source_empty_sections() {
        let ctx = makeContext()
        let engine = PaletteEngine(
            sources: [
                FakeSource(titles: [], category: "Recent", emptyStateTitles: ["Alpha", "Beta"]),
            ],
            context: ctx,
            pathSource: nil
        )
        let result = engine.search("")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].header, "Recent")
        XCTAssertEqual(result[0].items.map(\.title), ["Alpha", "Beta"])
    }

    func test_empty_query_skips_sources_that_return_no_empty_items() {
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
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].header, "B")
    }

    func test_active_query_merges_sources_and_sorts_by_score() {
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
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result[0].header) // merged section has no header
        XCTAssertEqual(result[0].items.count, 2)
    }

    func test_active_query_ranks_prefix_above_substring() {
        let ctx = makeContext()
        let engine = PaletteEngine(
            sources: [
                FakeSource(titles: ["stat", "git status"], category: "x", emptyStateTitles: nil),
            ],
            context: ctx,
            pathSource: nil
        )
        let result = engine.search("stat")
        XCTAssertEqual(result[0].items.map(\.title), ["stat", "git status"])
    }

    func test_path_query_uses_path_source_only() {
        let ctx = makeContext()
        let engine = PaletteEngine(
            sources: [
                FakeSource(titles: ["should not appear"], category: "x", emptyStateTitles: nil),
            ],
            context: ctx,
            pathSource: FakeSource(titles: ["/Users/me/dev"], category: "Path", emptyStateTitles: nil)
        )
        let result = engine.search("/Users")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].items.map(\.title), ["/Users/me/dev"])
    }

    func test_tilde_query_uses_path_source() {
        let ctx = makeContext()
        let engine = PaletteEngine(
            sources: [],
            context: ctx,
            pathSource: FakeSource(titles: ["~/dev"], category: nil, emptyStateTitles: nil)
        )
        let result = engine.search("~/dev")
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].items.map(\.title), ["~/dev"])
    }

    func test_path_query_with_empty_path_source_returns_empty() {
        let ctx = makeContext()
        let engine = PaletteEngine(
            sources: [FakeSource(titles: ["git"], category: nil, emptyStateTitles: nil)],
            context: ctx,
            pathSource: FakeSource(titles: [], category: nil, emptyStateTitles: nil)
        )
        XCTAssertTrue(engine.search("/nope").isEmpty)
    }

    func test_no_matches_returns_empty_sections() {
        let ctx = makeContext()
        let engine = PaletteEngine(
            sources: [FakeSource(titles: ["git"], category: "x", emptyStateTitles: nil)],
            context: ctx,
            pathSource: nil
        )
        XCTAssertTrue(engine.search("zzz").isEmpty)
    }

    func test_empty_state_groups_items_by_category() {
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
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].header, "A")
        XCTAssertEqual(result[0].items.count, 2)
        XCTAssertEqual(result[1].header, "B")
        XCTAssertEqual(result[1].items.count, 1)
    }
}
