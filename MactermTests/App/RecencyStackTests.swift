@testable import Macterm
import XCTest

final class RecencyStackTests: XCTestCase {
    func test_push_inserts_at_front() {
        var s = RecencyStack<Int>(limit: 5)
        s.push(1)
        s.push(2)
        s.push(3)
        XCTAssertEqual(s.items, [3, 2, 1])
    }

    func test_push_existing_moves_to_front() {
        var s = RecencyStack<Int>(limit: 5, items: [1, 2, 3])
        s.push(3)
        XCTAssertEqual(s.items, [3, 1, 2])
    }

    func test_push_already_at_front_is_noop() {
        var s = RecencyStack<Int>(limit: 5, items: [1, 2, 3])
        s.push(1)
        XCTAssertEqual(s.items, [1, 2, 3])
    }

    func test_push_respects_limit_dropping_oldest() {
        var s = RecencyStack<Int>(limit: 3)
        s.push(1)
        s.push(2)
        s.push(3)
        s.push(4)
        XCTAssertEqual(s.items, [4, 3, 2])
    }

    func test_init_truncates_to_limit() {
        let s = RecencyStack<Int>(limit: 2, items: [1, 2, 3, 4])
        XCTAssertEqual(s.items, [1, 2])
    }

    func test_remove_removes_by_value() {
        var s = RecencyStack<Int>(limit: 5, items: [1, 2, 3])
        s.remove(2)
        XCTAssertEqual(s.items, [1, 3])
    }

    func test_removeAll_empties() {
        var s = RecencyStack<Int>(limit: 5, items: [1, 2, 3])
        s.removeAll()
        XCTAssertTrue(s.isEmpty)
    }

    func test_prune_keeps_only_valid() {
        var s = RecencyStack<Int>(limit: 5, items: [1, 2, 3, 4])
        s.prune(keeping: [2, 4])
        XCTAssertEqual(s.items, [2, 4])
    }

    func test_popValid_returns_most_recent_in_set_and_removes_preceding_stale() {
        var s = RecencyStack<Int>(limit: 5, items: [1, 2, 3, 4])
        let got = s.popValid(in: [3])
        XCTAssertEqual(got, 3)
        // 1 and 2 should have been dropped as stale; 4 remains below 3.
        XCTAssertEqual(s.items, [4])
    }

    func test_popValid_returns_nil_if_none_match() {
        var s = RecencyStack<Int>(limit: 5, items: [1, 2, 3])
        XCTAssertNil(s.popValid(in: [99]))
        // All items drained.
        XCTAssertTrue(s.isEmpty)
    }

    func test_top_returns_limited_valid_in_order() {
        let s = RecencyStack<Int>(limit: 5, items: [4, 3, 2, 1])
        XCTAssertEqual(s.top(2, in: [1, 2, 3, 4]), [4, 3])
    }

    func test_top_excludes_given_id() {
        let s = RecencyStack<Int>(limit: 5, items: [4, 3, 2, 1])
        XCTAssertEqual(s.top(2, in: [1, 2, 3, 4], excluding: 4), [3, 2])
    }

    func test_top_skips_invalid_entries() {
        let s = RecencyStack<Int>(limit: 5, items: [4, 3, 2, 1])
        XCTAssertEqual(s.top(3, in: [1, 3]), [3, 1])
    }
}
