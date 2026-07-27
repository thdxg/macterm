import Foundation

enum TerminalCommandSubmission {
    /// Hardware key codes (Carbon `kVK_*`). Named rather than written inline:
    /// a transposed literal silently changes which keys count as a submission
    /// or wipe the evidence, and nothing downstream would notice. These mirror
    /// `HotkeyRegistry`'s vocabulary — pinned to it by
    /// `TerminalCommandSubmissionTests.keyCodesMatchHotkeyRegistry` rather than
    /// read from it directly, since that registry is `@MainActor` and this
    /// helper is deliberately isolation-free.
    private enum KeyCode {
        static let selectAll: UInt16 = 0 // A
        static let cut: UInt16 = 7 // X
        static let backspaceChord: UInt16 = 4 // H — ^H
        static let cancel: UInt16 = 8 // C — ^C
        static let killWord: UInt16 = 13 // W — ^W
        static let killLine: UInt16 = 32 // U — ^U
        static let killToEnd: UInt16 = 40 // K — ^K
        static let `return`: UInt16 = 36
        static let keypadEnter: UInt16 = 76
        static let delete: UInt16 = 51 // Backspace
        static let escape: UInt16 = 53
        static let forwardDelete: UInt16 = 117
    }

    private static let returnKeyCodes: Set<UInt16> = [KeyCode.return, KeyCode.keypadEnter]

    /// Keys that discard the line outright, no modifier needed.
    private static let discardingKeyCodes: Set<UInt16> = [
        KeyCode.escape, KeyCode.delete, KeyCode.forwardDelete,
    ]

    /// Control chords that destroy the current line or word, after which the
    /// recorded text no longer describes what is in the prompt buffer.
    private static let discardingControlKeyCodes: Set<UInt16> = [
        KeyCode.backspaceChord, KeyCode.cancel, KeyCode.killWord,
        KeyCode.killLine, KeyCode.killToEnd,
    ]

    /// Command chords that replace or remove the buffer wholesale.
    private static let discardingCommandKeyCodes: Set<UInt16> = [KeyCode.selectAll, KeyCode.cut]

    /// Best-effort evidence that the next Return submits actual prompt text.
    /// Terminal protocols do not expose a TUI's editor buffer, so the view
    /// records committed text it forwards and consumes that evidence on Return.
    /// This rejects a genuinely blank Return without naming any specific TUI.
    struct Evidence {
        private var hasContent = false

        mutating func recordText(_ text: String) {
            if TerminalCommandSubmission.textContainsContent(text) {
                hasContent = true
            }
        }

        mutating func consume() -> Bool {
            defer { hasContent = false }
            return hasContent
        }

        mutating func clear() {
            hasContent = false
        }
    }

    static func isReturn(
        keyCode: UInt16,
        isRepeat: Bool,
        hasMarkedText: Bool,
        hasUserModifiers: Bool
    ) -> Bool {
        returnKeyCodes.contains(keyCode) && !isRepeat && !hasMarkedText && !hasUserModifiers
    }

    static func textContainsNewline(_ text: String) -> Bool {
        text.contains("\n") || text.contains("\r")
    }

    static func textContainsContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    static func clearsInputEvidence(
        keyCode: UInt16,
        hasControl: Bool,
        hasCommand: Bool
    ) -> Bool {
        if discardingKeyCodes.contains(keyCode) { return true }
        if hasControl, discardingControlKeyCodes.contains(keyCode) { return true }
        if hasCommand, discardingCommandKeyCodes.contains(keyCode) { return true }
        return false
    }

    static func shouldRecordLiteralText(hasOption: Bool) -> Bool {
        // With macos-option-as-alt, interpretKeyEvents yields a printable base
        // character even though Ghostty sends it as Meta navigation. Prefer a
        // false negative over calling that navigation committed prompt text.
        !hasOption
    }
}
