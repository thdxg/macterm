import Foundation
@testable import Macterm
import Testing

struct RemoteProbeRequestTests {
    @Test
    func primed_request_is_pending_until_consumed() {
        var request = RemoteProbeRequest(primed: true)
        #expect(request.isPending)
        request.consume()
        #expect(!request.isPending)

        let unprimed = RemoteProbeRequest(primed: false)
        #expect(!unprimed.isPending)
    }

    @Test
    func boundary_request_rearms_after_consume() {
        var request = RemoteProbeRequest(primed: true)
        request.consume()
        request.request()
        #expect(request.isPending)
    }

    @Test
    func miss_retries_are_bounded() {
        var request = RemoteProbeRequest(primed: true)
        for _ in 0 ..< 16 {
            request.consume()
            request.noteMiss()
        }
        #expect(request.isPending)
        request.consume()
        request.noteMiss()
        #expect(!request.isPending)

        // An explicit boundary request is never budget-gated — the budget
        // bounds only registration-race retries.
        request.request()
        #expect(request.isPending)
    }
}
