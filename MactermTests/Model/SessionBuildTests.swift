import Foundation
@testable import Macterm
import Testing

struct SessionBuildTests {
    private func session(_ name: String, build: String?, running: Bool = true) -> LocalSession {
        LocalSession(name: name, isRunning: running, build: build)
    }

    @Test
    func a_session_of_another_build_is_older() {
        #expect(SessionBuild.isOlder("1.0.1+thdxg.aaa111", appKey: "bbb222"))
    }

    @Test
    func a_session_of_the_same_build_is_not_marked() {
        #expect(!SessionBuild.isOlder("1.0.1+thdxg.bbb222", appKey: "bbb222"))
    }

    @Test
    func nothing_is_marked_when_a_side_has_no_key() {
        #expect(!SessionBuild.isOlder("unknown", appKey: "bbb222"))
        #expect(!SessionBuild.isOlder("1.0.1", appKey: "bbb222"))
        #expect(!SessionBuild.isOlder(nil, appKey: "bbb222"))
        #expect(!SessionBuild.isOlder("1.0.1+thdxg.aaa111", appKey: nil))
    }

    @Test
    func only_running_sessions_of_another_build_are_listed() {
        let sessions = [
            session("old", build: "1.0.1+thdxg.aaa111"),
            session("new", build: "1.0.1+thdxg.bbb222"),
            session("gone", build: "1.0.1+thdxg.aaa111", running: false),
            session("unknown", build: "unknown"),
        ]
        #expect(SessionBuild.outdatedNames(in: sessions, appKey: "bbb222") == ["old"])
    }
}
