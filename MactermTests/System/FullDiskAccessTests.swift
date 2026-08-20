import Foundation
@testable import Macterm
import Testing

/// The live probe's answer depends on the machine running the tests (whether
/// the hosting app has the FDA grant), so coverage targets the pure verdict
/// over probe results, plus the System Settings deep link the banner opens.
struct FullDiskAccessTests {
    @Test
    func aReadableFileProvesTheGrant() {
        #expect(FullDiskAccess.verdict([.readable, .missing]) == true)
        // A denial alongside a readable file is some other restriction on
        // that one file — the grant itself is still proven.
        #expect(FullDiskAccess.verdict([.denied, .readable]) == true)
    }

    @Test
    func aDenialWithoutAReadableFileDisprovesIt() {
        #expect(FullDiskAccess.verdict([.denied, .missing]) == false)
        #expect(FullDiskAccess.verdict([.missing, .denied]) == false)
    }

    @Test
    func noEvidenceStaysUndecided() {
        #expect(FullDiskAccess.verdict([.missing, .missing]) == nil)
        #expect(FullDiskAccess.verdict([]) == nil)
    }

    @Test
    func settingsURLTargetsTheFullDiskAccessPane() {
        #expect(
            FullDiskAccess.settingsURL?.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
    }

    // The errno mapping is testable only at its deterministic edges — a
    // protected path's result depends on the host's grant. These two pin the
    // ends that never do.

    @Test
    func probeMapsAnAbsentPathToMissing() {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("fda-probe-\(UUID().uuidString)").path
        #expect(FullDiskAccess.probe(absent) == .missing)
    }

    @Test
    func probeMapsAnOpenableDirectoryToReadable() {
        #expect(FullDiskAccess.probe("/") == .readable)
    }
}
