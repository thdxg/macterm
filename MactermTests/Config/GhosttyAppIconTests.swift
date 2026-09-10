import Foundation
@testable import Macterm
import Testing

struct GhosttyAppIconTests {
    /// A fixed home so `~` expansion is deterministic, and no `~user` lookup.
    private func expand(_ path: String) -> String {
        if path == "~" { return "/Users/tester" }
        if path.hasPrefix("~/") { return "/Users/tester" + path.dropFirst() }
        return path
    }

    @Test
    func theDefaultAndOfficialStylesKeepTheBundledIcon() {
        #expect(GhosttyAppIcon.resolve(style: nil, customPath: nil, expandTilde: expand) == .bundled)
        #expect(GhosttyAppIcon.resolve(style: "official", customPath: nil, expandTilde: expand) == .bundled)
        // A path alone means nothing: Ghostty consults it only under `custom`.
        #expect(GhosttyAppIcon.resolve(style: "official", customPath: "/tmp/i.png", expandTilde: expand) == .bundled)
    }

    @Test
    func customWithAnAbsolutePathIsThatFile() {
        let icon = GhosttyAppIcon.resolve(style: "custom", customPath: "/tmp/icons/mine.png", expandTilde: expand)
        #expect(icon == .custom(URL(fileURLWithPath: "/tmp/icons/mine.png")))
    }

    @Test
    func tildeExpandsToTheHomeDirectory() {
        let icon = GhosttyAppIcon.resolve(style: "custom", customPath: "~/Pictures/term.icns", expandTilde: expand)
        #expect(icon == .custom(URL(fileURLWithPath: "/Users/tester/Pictures/term.icns")))
    }

    /// Ghostty's own default when `custom` names no file.
    @Test
    func customWithoutAPathUsesGhosttysDefaultLocation() {
        let expected = GhosttyAppIcon.custom(URL(fileURLWithPath: "/Users/tester/.config/ghostty/Ghostty.icns"))
        #expect(GhosttyAppIcon.resolve(style: "custom", customPath: nil, expandTilde: expand) == expected)
        // An explicitly empty value resets the key in ghostty's parser, so it
        // must read as unset here too.
        #expect(GhosttyAppIcon.resolve(style: "custom", customPath: "  ", expandTilde: expand) == expected)
    }

    /// A relative path would resolve against a GUI app's working directory,
    /// which the user can't predict — refuse rather than guess.
    @Test
    func aRelativePathIsInvalidAndFallsBack() {
        #expect(GhosttyAppIcon.resolve(style: "custom", customPath: "icons/mine.png", expandTilde: expand) == .bundled)
        #expect(GhosttyAppIcon.resolve(style: "custom", customPath: "./mine.png", expandTilde: expand) == .bundled)
    }

    @Test
    func surroundingWhitespaceIsTolerated() {
        let icon = GhosttyAppIcon.resolve(style: " custom ", customPath: " /tmp/i.png ", expandTilde: expand)
        #expect(icon == .custom(URL(fileURLWithPath: "/tmp/i.png")))
        #expect(GhosttyAppIcon.isCustom(style: " custom "))
    }

    /// `custom` is the only value that consults `macos-custom-icon`. Ghostty's
    /// `custom-style` is a *different* value (the colorized ghost), and reading
    /// it as "custom" would make every `custom-style` config adopt a path the
    /// user meant for nothing.
    @Test
    func onlyTheCustomValueConsultsThePath() {
        #expect(GhosttyAppIcon.macosIconCustom == "custom")
        #expect(GhosttyAppIcon.macosIconOfficial == "official")
        #expect(GhosttyAppIcon.isCustom(style: "custom"))
        #expect(!GhosttyAppIcon.isCustom(style: "custom-style"))
        #expect(!GhosttyAppIcon.isCustom(style: "official"))
        #expect(!GhosttyAppIcon.isCustom(style: nil))
    }

    /// Ghostty's artist variants and `custom-style` are Ghostty-brand artwork
    /// with no Macterm equivalent; they resolve to the bundled icon even when
    /// a custom path is also set.
    @Test
    func ghosttyArtworkStylesKeepTheBundledIcon() {
        let artwork = ["blueprint", "chalkboard", "glass", "holographic", "microchip", "paper", "retro", "xray", "custom-style"]
        for style in artwork {
            #expect(GhosttyAppIcon.resolve(style: style, customPath: "/tmp/i.png", expandTilde: expand) == .bundled)
            #expect(GhosttyAppIcon.isGhosttyArtwork(style: style))
        }
        #expect(!GhosttyAppIcon.isGhosttyArtwork(style: nil))
        #expect(!GhosttyAppIcon.isGhosttyArtwork(style: ""))
        #expect(!GhosttyAppIcon.isGhosttyArtwork(style: "official"))
        #expect(!GhosttyAppIcon.isGhosttyArtwork(style: "custom"))
    }

    /// The default expander is the same call Ghostty.app makes.
    @Test
    func theDefaultExpanderResolvesTildeToTheRealHome() {
        let icon = GhosttyAppIcon.resolve(style: "custom", customPath: "~/x.png")
        guard case let .custom(url) = icon else {
            Issue.record("expected a custom icon, got \(icon)")
            return
        }
        #expect(url.path == ("~/x.png" as NSString).expandingTildeInPath)
        #expect(url.path.hasPrefix("/"))
    }
}
