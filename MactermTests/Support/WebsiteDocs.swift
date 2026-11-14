import Foundation

/// The docs pages are in `docs/` of the macterm/website repository. A few tests
/// read them, so that a page and the code stay in step.
///
/// The checkout is `MACTERM_WEBSITE_DIR`, or else `website/` in the root of this
/// repository (git ignores it). Test CI checks it out there.
///
/// With no checkout, a test is off on a developer's Mac, and the trait says
/// why. On CI (`CI` is set) the test is on and fails, so that a missing
/// checkout never passes in silence.
enum WebsiteDocs {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Support
        .deletingLastPathComponent() // MactermTests
        .deletingLastPathComponent() // repo root

    /// The `docs/` folder of the website checkout, or nil if there is none.
    static let directory: URL? = {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["MACTERM_WEBSITE_DIR"].map { URL(fileURLWithPath: $0) },
            repositoryRoot.appendingPathComponent("website"),
        ].compactMap(\.self)
        return candidates
            .map { $0.appendingPathComponent("docs") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }()

    static var isRequired: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    /// For `.enabled(if:)`: the tests that read the docs run when there is a
    /// checkout, and always on CI.
    static var canRun: Bool {
        directory != nil || isRequired
    }

    struct MissingCheckout: Error, CustomStringConvertible {
        var description: String {
            "no checkout of macterm/website: set MACTERM_WEBSITE_DIR, or clone it to ./website"
        }
    }

    /// The docs folder. Throws on CI when there is no checkout.
    static func requireDirectory() throws -> URL {
        guard let directory else { throw MissingCheckout() }
        return directory
    }
}
