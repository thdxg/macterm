import AppKit
@testable import Macterm
import SwiftUI
import Testing

@MainActor
struct TerminalFontTests {
    @Test
    func no_family_is_the_system_monospaced_font() {
        let store = TerminalFont()
        let font = store.nsFont(size: 12)
        #expect(font.fontName == NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName)
        #expect(font.pointSize == 12)
    }

    @Test
    func a_family_keeps_the_size_and_takes_the_nearest_weight() {
        let store = TerminalFont(family: "Menlo")
        let regular = store.nsFont(size: 11)
        #expect(regular.familyName == "Menlo")
        #expect(regular.pointSize == 11)
        let bold = store.nsFont(size: 11, weight: .bold)
        #expect(bold.familyName == "Menlo")
        #expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
    }

    @Test
    func a_family_that_does_not_load_falls_back_to_the_system_font() {
        #expect(TerminalFont.font(family: "No Such Font 8d1f", size: 12, weight: .regular) == nil)
        let store = TerminalFont(family: "No Such Font 8d1f")
        #expect(store.nsFont(size: 12).fontName == NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName)
    }

    @Test
    func a_new_family_replaces_the_cached_fonts() {
        let store = TerminalFont(family: "Menlo")
        #expect(store.nsFont(size: 12).familyName == "Menlo")
        store.update(family: "Courier")
        #expect(store.nsFont(size: 12).familyName == "Courier")
        store.update(family: nil)
        #expect(store.family == nil)
        #expect(store.nsFont(size: 12).fontName == NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName)
    }

    @Test
    func text_styles_and_weights_map_to_appkit() {
        #expect(Font.TextStyle.caption.appKitPointSize == NSFont.preferredFont(forTextStyle: .caption1).pointSize)
        #expect(Font.TextStyle.callout.appKitPointSize == NSFont.preferredFont(forTextStyle: .callout).pointSize)
        #expect(Font.TextStyle.body.appKitPointSize == NSFont.preferredFont(forTextStyle: .body).pointSize)
        #expect(Font.Weight.semibold.appKitWeight == .semibold)
        #expect(Font.Weight.regular.appKitWeight == .regular)
        #expect(Font.Weight.bold.appKitWeight == .bold)
    }
}
