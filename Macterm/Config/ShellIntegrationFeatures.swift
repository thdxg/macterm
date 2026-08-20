import Foundation

/// Composes the `shell-integration-features` line Macterm writes into
/// `macterm-overrides.conf` so it *merges with* the user's own value instead
/// of replacing it (issue #75).
///
/// libghostty parses this key with replace semantics: every occurrence of the
/// key re-parses the comma list into a fresh default struct
/// (`parsePackedStruct` in ghostty's `src/cli/args.zig`). A bare
/// `shell-integration-features = no-ssh-env` in the overrides file — loaded
/// last — would therefore silently wipe user flags like `no-cursor` from
/// the selected user Ghostty config. So Macterm re-emits the user's effective
/// value first and appends its own forced `no-*` flags; ghostty applies the
/// comma-separated parts left to right with later parts winning per-flag, so
/// the forced flags take precedence while every other user flag survives.
///
/// Pure selection logic: the user's merged root-config text is passed in so
/// this is unit-testable without touching disk. A value set in a recursively
/// loaded `config-file` include still isn't seen.
enum ShellIntegrationFeatures {
    /// Every flag the bundled libghostty's `ShellIntegrationFeatures` struct
    /// knows (ghostty `src/config/Config.zig`). Needed to expand a bare
    /// `shell-integration-features = true` ("all on") into an explicit list
    /// the forced `no-*` flags can be appended to — ghostty accepts a bool
    /// literal only as the *entire* value, never as one comma part. Must
    /// track the bundled GhosttyKit when the feature set changes.
    static let allFeatures = ["cursor", "sudo", "title", "ssh-env", "ssh-terminfo", "path"]

    /// The bool literals ghostty's `parseBool` accepts (`src/cli/args.zig`).
    private static let trueLiterals: Set<String> = ["1", "t", "T", "true"]
    private static let falseLiterals: Set<String> = ["0", "f", "F", "false"]

    /// The user's effective `shell-integration-features` value in raw ghostty
    /// config text. Last occurrence wins and an empty value resets the key to
    /// its defaults ("not set"), mirroring libghostty's own semantics.
    /// Comments and blank lines are ignored; a matched pair of surrounding
    /// double quotes is stripped. nil when the key is never set.
    static func userValue(inConfigText text: String) -> String? {
        var result: String?
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex ..< eq].trimmingCharacters(in: .whitespaces)
            guard key == "shell-integration-features" else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            result = value.isEmpty ? nil : value
        }
        return result
    }

    /// ghostty's own defaults for the features it knows, read off
    /// `ghostty +show-config --default` on the pinned build:
    /// `cursor,no-sudo,title,no-ssh-env,no-ssh-terminfo,path`. Needed because
    /// "the user didn't mention this flag" is not the same answer for every
    /// flag — notably `ssh-terminfo` is OFF unless asked for.
    private static let featureDefaults: [String: Bool] = [
        "cursor": true, "sudo": false, "title": true,
        "ssh-env": false, "ssh-terminfo": false, "path": true,
    ]

    /// Whether `feature` is on in the USER's ghostty config, falling back to
    /// ghostty's own default when they never mention it. Last mention wins and
    /// a `no-` prefix turns it off, matching libghostty's left-to-right
    /// per-flag application; a bool literal (valid only as the entire value)
    /// flips everything at once.
    ///
    /// Deliberately reads the user's RAW config, not the effective value after
    /// `macterm-overrides.conf`: the overrides re-emit this key to force
    /// plumbing flags (`no-path` — see `MactermConfig.regenerate`), and a
    /// consumer of an intent flag like `ssh-terminfo` must never be coupled to
    /// whatever plumbing Macterm happens to force alongside it.
    static func isEnabled(_ feature: String, inConfigText text: String?) -> Bool {
        let fallback = featureDefaults[feature] ?? false
        guard let text, let value = userValue(inConfigText: text) else { return fallback }
        if trueLiterals.contains(value) { return true }
        if falseLiterals.contains(value) { return false }
        var enabled = fallback
        for part in value.split(separator: ",") {
            let flag = part.trimmingCharacters(in: .whitespaces)
            if flag == feature { enabled = true }
            if flag == "no-\(feature)" { enabled = false }
        }
        return enabled
    }

    /// The value to write after `shell-integration-features = ` in
    /// macterm-overrides.conf, or nil when no override line is needed.
    /// `disabled` are the `no-*` flags Macterm must force (see
    /// `MactermConfig.regenerate`).
    static func overrideValue(userConfigText: String?, disabled: [String]) -> String? {
        guard !disabled.isEmpty else { return nil }
        let ours = disabled.joined(separator: ",")
        guard let text = userConfigText, let user = userValue(inConfigText: text) else { return ours }
        // A bool literal flips every flag at once and is only valid as the
        // whole value: expand "all on" to the explicit list so our flags can
        // follow; "all off" already includes everything we'd disable.
        if trueLiterals.contains(user) {
            return (allFeatures + disabled).joined(separator: ",")
        }
        if falseLiterals.contains(user) {
            return "false"
        }
        return "\(user),\(ours)"
    }
}
