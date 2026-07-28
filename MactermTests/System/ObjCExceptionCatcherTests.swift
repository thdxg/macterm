import Foundation
@testable import Macterm
import Testing

/// Covers the ObjC exception trampoline behind `catchingObjCException` — the
/// guard that lets known-flaky AppKit calls (quick-terminal ordering) fail
/// soft instead of killing the process.
@MainActor
struct ObjCExceptionCatcherTests {
    @Test
    func returns_nil_and_runs_the_body_when_nothing_throws() {
        var ran = false
        let caught = catchingObjCException { ran = true }
        #expect(ran)
        #expect(caught == nil)
    }

    @Test
    func returns_the_raised_exception_with_name_and_reason_intact() {
        let caught = catchingObjCException {
            NSException(name: .internalInconsistencyException, reason: "synthetic test exception", userInfo: nil).raise()
        }
        #expect(caught?.name == .internalInconsistencyException)
        #expect(caught?.reason == "synthetic test exception")
    }

    @Test
    func code_after_a_raise_is_not_executed() {
        var reached = false
        let caught = catchingObjCException {
            NSException(name: .genericException, reason: nil, userInfo: nil).raise()
            reached = true
        }
        #expect(caught != nil)
        #expect(!reached)
    }
}
