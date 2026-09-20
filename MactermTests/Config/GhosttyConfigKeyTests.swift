import AppKit
import GhosttyKit
@testable import Macterm
import Testing

/// Each `GhosttyConfigKey` factory pairs a key with the C shape libghostty
/// writes for it. These read a real, finalized config, so a factory handed
/// the wrong out-parameter (the `macos-hidden`-through-`ghostty_string_s`
/// bug) fails here instead of reading empty in the app.
@MainActor
struct GhosttyConfigKeyTests {
    /// A finalized config loaded from `text`.
    private func makeConfig(_ text: String) throws -> ghostty_config_t {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-config-key-\(UUID().uuidString).conf")
        try text.write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let config = try #require(ghostty_config_new())
        ghostty_config_load_file(config, file.path)
        ghostty_config_finalize(config)
        return config
    }

    /// Every shape under test set to a known value.
    private static let everyShape = """
    background = #112233
    palette = 4=#0a0b0c
    unfocused-split-opacity = 0.25
    bell-features = audio,attention
    bell-audio-path = /tmp/ding.wav
    bell-audio-volume = 0.75
    macos-auto-secure-input = false
    macos-hidden = always
    macos-icon = custom
    """

    @Test
    func everyShapeReadsTheValueTheConfigSet() throws {
        let config = try makeConfig(Self.everyShape)
        defer { ghostty_config_free(config) }

        #expect(GhosttyConfigKey.bool("macos-auto-secure-input").read(from: config) == false)
        #expect(GhosttyConfigKey.double("unfocused-split-opacity").read(from: config) == 0.25)
        #expect(GhosttyConfigKey.double("bell-audio-volume").read(from: config) == 0.75)
        // A packed struct's value is a set of modifiers over ghostty's default,
        // so assert the two bits the config named rather than the whole word.
        let bell = try #require(GhosttyConfigKey.packed("bell-features").read(from: config))
        #expect(bell & (1 << 1) != 0 && bell & (1 << 2) != 0)
        #expect(GhosttyConfigKey.tag("macos-hidden").read(from: config) == "always")
        #expect(GhosttyConfigKey.tag("macos-icon").read(from: config) == "custom")
        #expect(GhosttyConfigKey.path("bell-audio-path").read(from: config) == "/tmp/ding.wav")

        let background = try #require(GhosttyConfigKey.color("background").read(from: config))
        #expect(Int(background.redComponent * 255) == 0x11)
        #expect(Int(background.greenComponent * 255) == 0x22)
        #expect(Int(background.blueComponent * 255) == 0x33)

        let palette = try #require(GhosttyConfigKey.palette("palette").read(from: config))
        #expect(palette.count == 256)
        #expect(Int(palette[4].redComponent * 255) == 0x0A)
        #expect(Int(palette[4].blueComponent * 255) == 0x0C)
    }

    @Test
    func unsetOptionalsAndUnknownKeysReadNil() throws {
        let config = try makeConfig("macos-icon = custom")
        defer { ghostty_config_free(config) }

        // An unset `?[:0]const u8` is a null pointer behind a *true* return.
        #expect(GhosttyConfigKey.tag("macos-custom-icon").read(from: config) == nil)
        // An unset Path is an empty string, which reads as unset.
        #expect(GhosttyConfigKey.path("bell-audio-path").read(from: config) == nil)
        // A key libghostty doesn't know fails the getter outright.
        #expect(GhosttyConfigKey.bool("no-such-macterm-key").read(from: config) == nil)
        #expect(GhosttyConfigKey.tag("no-such-macterm-key").read(from: config) == nil)
    }

    @Test
    func theDomainKeysSpellGhosttysNames() {
        // Wire contracts: renaming any of these breaks the read silently.
        #expect(MacosHidden.key.name == "macos-hidden")
        #expect(ShortcutsAccess.key.name == "macos-shortcuts")
        #expect(GhosttyAppIcon.styleKey.name == "macos-icon")
        #expect(GhosttyAppIcon.customPathKey.name == "macos-custom-icon")
    }
}
