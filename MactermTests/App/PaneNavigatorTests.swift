@testable import Macterm
import Testing

struct PaneNavigatorTests {
    @Test
    func record_appends_and_advances_cursor() {
        var n = PaneNavigator<Int>()
        n.record(1)
        n.record(2)
        n.record(3)
        #expect(n.trail == [1, 2, 3])
        #expect(n.current == 3)
    }

    @Test
    func record_same_id_is_noop() {
        var n = PaneNavigator<Int>()
        n.record(1)
        n.record(1)
        #expect(n.trail == [1])
    }

    @Test
    func back_then_forward_returns_to_origin() {
        var n = PaneNavigator<Int>()
        n.record(1)
        n.record(2)
        n.record(3)
        #expect(n.back() == 2)
        #expect(n.back() == 1)
        #expect(n.forward() == 2)
        #expect(n.forward() == 3)
    }

    @Test
    func back_at_start_returns_nil() {
        var n = PaneNavigator<Int>()
        n.record(1)
        #expect(n.back() == nil)
        #expect(n.current == 1)
    }

    @Test
    func forward_at_end_returns_nil() {
        var n = PaneNavigator<Int>()
        n.record(1)
        n.record(2)
        #expect(n.forward() == nil)
        #expect(n.current == 2)
    }

    @Test
    func record_after_back_truncates_forward_trail() {
        var n = PaneNavigator<Int>()
        n.record(1)
        n.record(2)
        n.record(3)
        _ = n.back() // -> 2
        n.record(4) // branches: drops 3
        #expect(n.trail == [1, 2, 4])
        #expect(n.forward() == nil)
        #expect(n.back() == 2)
    }

    @Test
    func prune_drops_invalid_and_reanchors_cursor() {
        var n = PaneNavigator<Int>()
        n.record(1)
        n.record(2)
        n.record(3)
        _ = n.back() // cursor on 2
        n.prune(keeping: [1, 2]) // 3 is gone
        #expect(n.trail == [1, 2])
        #expect(n.current == 2)
    }

    @Test
    func prune_removing_current_falls_back_to_end() {
        var n = PaneNavigator<Int>()
        n.record(1)
        n.record(2)
        n.record(3) // cursor on 3
        n.prune(keeping: [1, 2]) // current (3) removed
        #expect(n.trail == [1, 2])
        #expect(n.current == 2)
    }

    @Test
    func limit_keeps_most_recent() {
        var n = PaneNavigator<Int>(limit: 3)
        for i in 1 ... 5 {
            n.record(i)
        }
        #expect(n.trail == [3, 4, 5])
        #expect(n.current == 5)
    }
}
