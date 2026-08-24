import Foundation

/// Reads a single key out of raw ghostty config text.
///
/// Raw text, not the loaded C config, for the reason `ShellIntegrationFeatures`
/// spells out: some consumers need the value the user *stated*, and the C API
/// cannot distinguish "explicitly set to the default" from "never mentioned".
/// A value set in a recursively loaded `config-file` include is not seen —
/// libghostty resolves those at load time and this only scans the root files.
enum GhosttyConfigText {
    /// The effective value of `key`, mirroring libghostty's own semantics:
    /// the last occurrence wins, and an **empty** value resets the key to its
    /// default rather than setting it to the empty string. Comments and blank
    /// lines are skipped, and one matched pair of surrounding double quotes is
    /// stripped. nil when the key is never set (or only reset).
    static func lastValue(of key: String, inConfigText text: String) -> String? {
        var result: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let lineKey = line[line.startIndex ..< eq].trimmingCharacters(in: .whitespaces)
            guard lineKey == key else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            result = value.isEmpty ? nil : value
        }
        return result
    }

    /// The bool literals ghostty's `parseBool` accepts (`src/cli/args.zig`).
    static let trueLiterals: Set<String> = ["1", "t", "T", "true"]
    static let falseLiterals: Set<String> = ["0", "f", "F", "false"]
}
