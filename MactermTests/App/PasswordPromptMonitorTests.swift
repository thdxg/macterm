import AppKit
@testable import Macterm
import Testing

@MainActor
struct PasswordKeyInputTests {
    private func key(
        _ chars: String,
        ignoring: String? = nil,
        code: UInt16,
        _ flags: NSEvent.ModifierFlags = []
    ) -> PasswordKeyInput? {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: chars,
            charactersIgnoringModifiers: ignoring ?? chars.lowercased(),
            isARepeat: false,
            keyCode: code
        )
        return event.flatMap(PasswordKeyInput.from)
    }

    @Test
    func printable_keys_are_text() {
        #expect(key("a", code: 0) == .text("a"))
        #expect(key("A", code: 0, .shift) == .text("A"))
        #expect(key("\t", code: 48) == .text("\t"))
        #expect(key("å", code: 0, .option) == .text("å"))
    }

    @Test
    func line_keys_map_to_their_tty_meaning() {
        #expect(key("\r", code: 36) == .submit)
        #expect(key("\r", code: 76) == .submit)
        #expect(key("\u{7f}", code: 51) == .backspace)
        #expect(key("\u{15}", ignoring: "u", code: 32, .control) == .killLine)
        #expect(key("\u{17}", ignoring: "w", code: 13, .control) == .killWord)
        #expect(key("\u{03}", ignoring: "c", code: 8, .control) == .cancel)
    }

    @Test
    func unmirrorable_keys_taint_and_command_chords_are_not_input() {
        #expect(key("\u{1b}", code: 53) == .unknown)
        #expect(key("\u{f700}", code: 126) == .unknown)
        #expect(key("\u{12}", ignoring: "r", code: 15, .control) == .unknown)
        #expect(key("v", code: 9, .command) == nil)
    }
}
