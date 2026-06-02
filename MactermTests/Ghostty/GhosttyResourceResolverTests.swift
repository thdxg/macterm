import Foundation
@testable import Macterm
import Testing

struct GhosttyResourceResolverTests {
    /// Build a resolver whose filesystem probe returns true only for the given
    /// set of existing paths.
    private func resolver(
        candidates: [String],
        existing: Set<String>
    ) -> GhosttyResourceResolver {
        GhosttyResourceResolver(
            candidates: candidates,
            fileExists: { existing.contains($0) }
        )
    }

    @Test
    func picks_first_candidate_with_shell_integration() {
        let r = resolver(
            candidates: ["/bundle/ghostty", "/Applications/Ghostty.app/Contents/Resources/ghostty"],
            existing: [
                "/bundle/ghostty/shell-integration",
                "/Applications/Ghostty.app/Contents/Resources/ghostty/shell-integration",
            ]
        )
        #expect(r.resolve() == "/bundle/ghostty")
    }

    @Test
    func skips_candidate_missing_shell_integration() {
        // First candidate lacks shell-integration; resolver falls through.
        let r = resolver(
            candidates: ["/bundle/ghostty", "/ghostty"],
            existing: ["/ghostty/shell-integration"]
        )
        #expect(r.resolve() == "/ghostty")
    }

    @Test
    func returns_nil_when_no_candidate_qualifies() {
        let r = resolver(
            candidates: ["/bundle/ghostty", "/ghostty"],
            existing: ["/bundle/ghostty/themes"] // themes alone is not enough
        )
        #expect(r.resolve() == nil)
    }
}
