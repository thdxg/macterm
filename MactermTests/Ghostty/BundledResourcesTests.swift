import Foundation
@testable import Macterm
import Testing

/// Verifies the ghostty resources Macterm ships in its bundle are complete and
/// laid out correctly — the regression class behind issues #39/#40, where a
/// resources dir missing (or misplaced) `terminfo/` left `TERM=xterm-ghostty`
/// unresolvable and broke key input.
///
/// These assert against `Macterm/Resources/` in the repo (where `setup.sh`
/// extracts the downloaded `ghostty-resources.tar.gz`), i.e. the exact tree
/// folder-referenced into the app bundle. The layout mirrors a real
/// Ghostty.app: `ghostty/{themes,shell-integration}` plus a SIBLING `terminfo/`.
/// On a fresh checkout before `mise run setup`, the dir is absent — tests skip
/// rather than fail so they don't block an unprepared dev environment, but run
/// in CI where setup has happened.
struct BundledResourcesTests {
    /// Repo `Macterm/Resources` dir, located relative to this source file.
    private static let resourcesDir: URL? = {
        // …/MactermTests/Ghostty/BundledResourcesTests.swift → repo root is 3 up.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Ghostty
            .deletingLastPathComponent() // MactermTests
            .deletingLastPathComponent() // repo root
        let dir = root.appendingPathComponent("Macterm/Resources")
        return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
    }()

    private func exists(_ relativePath: String) -> Bool {
        guard let base = Self.resourcesDir else { return false }
        return FileManager.default.fileExists(
            atPath: base.appendingPathComponent(relativePath).path
        )
    }

    /// True once `setup.sh` has populated resources — gate every assertion on
    /// this so a fresh checkout skips instead of failing.
    private var resourcesPresent: Bool { Self.resourcesDir != nil }

    @Test
    func terminfo_is_a_sibling_of_the_ghostty_resources_dir() throws {
        try #require(resourcesPresent, "run `mise run setup` to populate Macterm/Resources")
        // THE load-bearing invariant. GHOSTTY_RESOURCES_DIR points at
        // Resources/ghostty, and libghostty derives TERMINFO as
        // dirname(GHOSTTY_RESOURCES_DIR)/terminfo = Resources/terminfo. So
        // terminfo MUST sit beside ghostty/, never inside it. A flat layout
        // (terminfo under Resources/ghostty/) reintroduces #39/#40.
        #expect(exists("ghostty/shell-integration"), "resources dir Resources/ghostty missing")
        #expect(exists("terminfo"), "terminfo/ must be a sibling of ghostty/ (libghostty derives it via dirname)")
        #expect(!exists("ghostty/terminfo"), "terminfo must NOT live inside ghostty/ — that breaks the dirname derivation")
    }

    @Test
    func terminfo_contains_xterm_ghostty_entry() throws {
        try #require(resourcesPresent, "run `mise run setup` to populate Macterm/Resources")
        // macOS ncurses reads a hashed layout: the first letter of the entry is
        // its hex ASCII code, so xterm-ghostty lives under terminfo/78/ (x=0x78),
        // NOT terminfo/x/. This is the exact entry whose absence broke #39/#40.
        #expect(
            exists("terminfo/78/xterm-ghostty"),
            "compiled xterm-ghostty entry missing from terminfo tree"
        )
    }

    @Test
    func shell_integration_ships_for_every_supported_shell() throws {
        try #require(resourcesPresent, "run `mise run setup` to populate Macterm/Resources")
        for shell in ["bash", "zsh", "fish", "elvish", "nushell"] {
            #expect(
                exists("ghostty/shell-integration/\(shell)"),
                "ghostty/shell-integration/\(shell) missing — libghostty reads this at runtime"
            )
        }
    }

    @Test
    func themes_are_bundled() throws {
        try #require(resourcesPresent, "run `mise run setup` to populate Macterm/Resources")
        // A well-known ghostty theme the default config references (the bundled
        // themes are upstream's iTerm2-Color-Schemes names, spaces and all).
        #expect(exists("ghostty/themes/Rose Pine"), "expected bundled ghostty theme missing")
    }
}
