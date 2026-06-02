import Foundation
@testable import Macterm
import Testing

struct GhosttyCLITests {
    private func cli(candidates: [String], executable: Set<String>) -> GhosttyCLI {
        GhosttyCLI(
            binDirCandidates: candidates,
            isExecutable: { executable.contains($0) }
        )
    }

    @Test
    func resolves_first_candidate_with_executable() {
        let c = cli(
            candidates: ["/Applications/Ghostty.app/Contents/MacOS", "/home/Ghostty.app/Contents/MacOS"],
            executable: ["/home/Ghostty.app/Contents/MacOS/ghostty"]
        )
        #expect(c.resolveBinDir() == "/home/Ghostty.app/Contents/MacOS")
        #expect(c.isInstalled)
    }

    @Test
    func prefers_higher_priority_candidate() {
        let c = cli(
            candidates: ["/a", "/b"],
            executable: ["/a/ghostty", "/b/ghostty"]
        )
        #expect(c.resolveBinDir() == "/a")
    }

    @Test
    func not_installed_when_no_executable() {
        let c = cli(candidates: ["/a", "/b"], executable: [])
        #expect(c.resolveBinDir() == nil)
        #expect(!c.isInstalled)
    }
}
