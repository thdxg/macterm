import AppKit
@testable import Macterm
import Testing

@MainActor
struct MacosHiddenTests {
    /// The raw values are ghostty's own `MacHidden` tag names — what
    /// `ghostty_config_get` hands back for the key — so a rename here is a wire
    /// break, not a refactor.
    @Test
    func theWireVocabularyIsGhosttysOwn() {
        #expect(MacosHidden.allCases.map(\.rawValue) == ["never", "always"])
        #expect(MacosHidden.key == "macos-hidden")
    }

    @Test
    func anUnsetKeyIsGhosttysDefault() {
        #expect(MacosHidden.resolve(configValue: nil) == .never)
        #expect(MacosHidden.resolve(configValue: "") == .never)
        #expect(MacosHidden.resolve(configValue: "   ") == .never)
    }

    @Test
    func readsBothValues() {
        #expect(MacosHidden.resolve(configValue: "never") == .never)
        #expect(MacosHidden.resolve(configValue: "always") == .always)
    }

    /// libghostty hands back a bare tag, but the read goes through a C string
    /// and the value is user-authored — tolerate the shapes that cost nothing.
    @Test
    func toleratesSurroundingSpaceAndCase() {
        #expect(MacosHidden.resolve(configValue: " always ") == .always)
        #expect(MacosHidden.resolve(configValue: "ALWAYS") == .always)
    }

    /// A value from a newer ghostty than this build knows must degrade to the
    /// VISIBLE app: an app that silently drops its Dock tile, menu bar and
    /// ⌘-Tab entry over an unrecognized word has no route back.
    @Test
    func anUnrecognizedValueStaysVisible() {
        #expect(MacosHidden.resolve(configValue: "sometimes") == .never)
        #expect(MacosHidden.resolve(configValue: "true") == .never)
    }

    @Test
    func mapsToTheActivationPolicy() {
        #expect(MacosHidden.never.activationPolicy == .regular)
        #expect(MacosHidden.always.activationPolicy == .accessory)
    }

    /// The unit suite runs hosted inside the app, which is a regular app — so
    /// this doubles as a guard that the tests never leave the policy moved.
    @Test
    func theHostAppIsNotAnAccessory() {
        #expect(!MacosHidden.isRunningAsAccessory)
    }
}
