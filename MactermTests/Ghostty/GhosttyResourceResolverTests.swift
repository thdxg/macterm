import Foundation
@testable import Macterm
import Testing

struct GhosttyResourceResolverTests {
    /// Build a resolver whose filesystem probe returns true only for the given
    /// set of existing paths.
    private func resolver(
        candidates: [String],
        bundle: String?,
        existing: Set<String>
    ) -> GhosttyResourceResolver {
        GhosttyResourceResolver(
            candidates: candidates,
            bundleResourcesDir: bundle,
            fileExists: { existing.contains($0) }
        )
    }

    @Test
    func picks_bundle_over_ghostty_app() {
        let r = resolver(
            candidates: ["/bundle", "/Applications/Ghostty.app/Contents/Resources/ghostty"],
            bundle: "/bundle",
            existing: [
                "/bundle/shell-integration", "/bundle/terminfo",
                "/Applications/Ghostty.app/Contents/Resources/ghostty/shell-integration",
            ]
        )
        let res = r.resolve()
        #expect(res?.resourcesDir == "/bundle")
        #expect(res?.terminfoDir == "/bundle/terminfo")
    }

    @Test
    func skips_candidate_missing_shell_integration() {
        // First candidate lacks shell-integration; resolver falls through.
        let r = resolver(
            candidates: ["/bundle", "/ghostty"],
            bundle: "/bundle",
            existing: ["/ghostty/shell-integration"]
        )
        let res = r.resolve()
        #expect(res?.resourcesDir == "/ghostty")
    }

    @Test
    func returns_nil_when_no_candidate_qualifies() {
        let r = resolver(
            candidates: ["/bundle", "/ghostty"],
            bundle: "/bundle",
            existing: ["/bundle/themes"] // themes alone is not enough
        )
        #expect(r.resolve() == nil)
    }

    @Test
    func sets_terminfo_only_for_bundle_not_ghostty_app_fallback() {
        // Bundle missing shell-integration, so we fall back to Ghostty.app.
        // libghostty derives TERMINFO itself there, so we must NOT set it.
        let r = resolver(
            candidates: ["/bundle", "/ghostty"],
            bundle: "/bundle",
            existing: ["/ghostty/shell-integration", "/ghostty/terminfo"]
        )
        let res = r.resolve()
        #expect(res?.resourcesDir == "/ghostty")
        #expect(res?.terminfoDir == nil)
    }

    @Test
    func leaves_terminfo_unset_when_bundle_lacks_terminfo() {
        // Regression guard for #39/#40: bundle resolves but has no terminfo/.
        // We must not point TERMINFO at a nonexistent dir.
        let r = resolver(
            candidates: ["/bundle"],
            bundle: "/bundle",
            existing: ["/bundle/shell-integration"] // no /bundle/terminfo
        )
        let res = r.resolve()
        #expect(res?.resourcesDir == "/bundle")
        #expect(res?.terminfoDir == nil)
    }

    @Test
    func sets_terminfo_when_bundle_has_it() {
        let r = resolver(
            candidates: ["/bundle"],
            bundle: "/bundle",
            existing: ["/bundle/shell-integration", "/bundle/terminfo"]
        )
        #expect(r.resolve()?.terminfoDir == "/bundle/terminfo")
    }
}
