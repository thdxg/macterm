import Foundation

enum TerminalCommandSubmission {
    private static let returnKeyCodes: Set<UInt16> = [36, 76]

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
        if keyCode == 53 || keyCode == 51 || keyCode == 117 { return true } // Escape / delete
        if hasControl, [4, 8, 13, 32, 40].contains(keyCode) { return true } // H/C/W/U/K
        if hasCommand, [0, 7].contains(keyCode) { return true } // Select-all / cut
        return false
    }

    static func shouldRecordLiteralText(hasOption: Bool) -> Bool {
        // With macos-option-as-alt, interpretKeyEvents yields a printable base
        // character even though Ghostty sends it as Meta navigation. Prefer a
        // false negative over calling that navigation committed prompt text.
        !hasOption
    }
}
