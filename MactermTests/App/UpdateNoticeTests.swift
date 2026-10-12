@testable import Macterm
import Testing

/// The update toast: shown only when the recorded version differs from the
/// running one.
struct UpdateNoticeTests {
    @Test
    func names_the_new_version_after_an_update() {
        #expect(UpdateNotice.title(previous: "1.24.0", current: "1.25.0") == "Macterm updated to v1.25.0")
    }

    @Test
    func keeps_prerelease_suffixes() {
        #expect(UpdateNotice.title(previous: "1.24.2-tip.6", current: "1.24.2-tip.7") == "Macterm updated to v1.24.2-tip.7")
    }

    @Test
    func stays_quiet_when_the_version_did_not_change() {
        #expect(UpdateNotice.title(previous: "1.25.0", current: "1.25.0") == nil)
    }

    @Test
    func stays_quiet_without_a_recorded_version() {
        // A fresh install, or the first launch of a build with this feature.
        #expect(UpdateNotice.title(previous: nil, current: "1.25.0") == nil)
        #expect(UpdateNotice.title(previous: "", current: "1.25.0") == nil)
    }
}
