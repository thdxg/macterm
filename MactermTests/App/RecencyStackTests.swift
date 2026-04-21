@testable import Macterm
import Testing

struct RecencyStackTests {
    @Test
    func push_inserts_at_front() {
        var s = RecencyStack<Int>(limit: 5)
        s.push(1)
        s.push(2)
        s.push(3)
        #expect(s.items == [3, 2, 1])
    }

    @Test
    func push_existing_moves_to_front() {
        var s = RecencyStack<Int>(limit: 5, items: [1, 2, 3])
        s.push(3)
        #expect(s.items == [3, 1, 2])
    }

    @Test
    func push_already_at_front_is_noop() {
        var s = RecencyStack<Int>(limit: 5, items: [1, 2, 3])
        s.push(1)
        #expect(s.items == [1, 2, 3])
    }

    @Test
    func push_respects_limit_dropping_oldest() {
        var s = RecencyStack<Int>(limit: 3)
        s.push(1)
        s.push(2)
        s.push(3)
        s.push(4)
        #expect(s.items == [4, 3, 2])
    }

    @Test
    func init_truncates_to_limit() {
        let s = RecencyStack<Int>(limit: 2, items: [1, 2, 3, 4])
        #expect(s.items == [1, 2])
    }

    @Test
    func remove_removes_by_value() {
        var s = RecencyStack<Int>(limit: 5, items: [1, 2, 3])
        s.remove(2)
        #expect(s.items == [1, 3])
    }

    @Test
    func removeAll_empties() {
        var s = RecencyStack<Int>(limit: 5, items: [1, 2, 3])
        s.removeAll()
        #expect(s.isEmpty)
    }

    @Test
    func prune_keeps_only_valid() {
        var s = RecencyStack<Int>(limit: 5, items: [1, 2, 3, 4])
        s.prune(keeping: [2, 4])
        #expect(s.items == [2, 4])
    }

    @Test
    func popValid_returns_most_recent_in_set_and_removes_preceding_stale() {
        var s = RecencyStack<Int>(limit: 5, items: [1, 2, 3, 4])
        let got = s.popValid(in: [3])
        #expect(got == 3)
        // 1 and 2 should have been dropped as stale; 4 remains below 3.
        #expect(s.items == [4])
    }

    @Test
    func popValid_returns_nil_if_none_match() {
        var s = RecencyStack<Int>(limit: 5, items: [1, 2, 3])
        #expect(s.popValid(in: [99]) == nil)
        // All items drained.
        #expect(s.isEmpty)
    }

    @Test
    func top_returns_limited_valid_in_order() {
        let s = RecencyStack<Int>(limit: 5, items: [4, 3, 2, 1])
        #expect(s.top(2, in: [1, 2, 3, 4]) == [4, 3])
    }

    @Test
    func top_excludes_given_id() {
        let s = RecencyStack<Int>(limit: 5, items: [4, 3, 2, 1])
        #expect(s.top(2, in: [1, 2, 3, 4], excluding: 4) == [3, 2])
    }

    @Test
    func top_skips_invalid_entries() {
        let s = RecencyStack<Int>(limit: 5, items: [4, 3, 2, 1])
        #expect(s.top(3, in: [1, 3]) == [3, 1])
    }
}
