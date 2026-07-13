import Foundation

/// A bundled AI coding-agent logo, matched from a pane's live foreground
/// process so the sidebar shows *which* agent runs in a tab instead of the
/// generic tab icon. The raw value is the asset-catalog image name (a
/// monochrome template image, tinted like an SF Symbol).
enum AgentIcon: String {
    case claude = "AgentClaude"
    case codex = "AgentCodex"
    case opencode = "AgentOpenCode"
    case cursor = "AgentCursor"
    case gemini = "AgentGemini"
    case copilot = "AgentCopilot"
    case grok = "AgentGrok"

    /// Agent CLI names, matched against a process's kernel `comm` (the
    /// executable's basename, truncated to 15 chars) and its argv[0] basename.
    /// Both are needed: an agent's *binary* often isn't named after the CLI —
    /// brew's codex is `codex-aarch64-apple-darwin` (comm `codex-aarch64-a`),
    /// and Claude Code's native install execs a versioned binary whose comm is
    /// the bare version (`2.1.207`) while argv[0] stays `claude`.
    private static let processNames: [String: AgentIcon] = [
        "claude": .claude,
        "codex": .codex,
        "opencode": .opencode,
        "cursor-agent": .cursor,
        "gemini": .gemini,
        "copilot": .copilot,
        "grok": .grok,
    ]

    /// The agent running as `processName`, or nil for anything else
    /// (shells, ordinary programs, nil before the surface exists). An exact
    /// match wins; otherwise a known name followed by a non-alphanumeric
    /// separator matches (`codex-aarch64-a` → codex), so arch/version suffixes
    /// don't defeat detection while `claudette` still doesn't match `claude`.
    static func match(processName: String?) -> AgentIcon? {
        guard let name = processName?.lowercased() else { return nil }
        if let exact = processNames[name] { return exact }
        for (key, icon) in processNames where name.hasPrefix(key) {
            if let next = name.dropFirst(key.count).first, !next.isLetter, !next.isNumber {
                return icon
            }
        }
        return nil
    }

    /// Match against the kernel `comm` first (already in hand from the poll),
    /// falling back to the argv[0] basename — read lazily, only when `comm`
    /// doesn't identify an agent — for installs whose binary name carries no
    /// CLI name at all (Claude Code's versioned binary).
    static func match(comm: String?, argv0 fallback: () -> String?) -> AgentIcon? {
        if let icon = match(processName: comm) { return icon }
        return match(processName: fallback())
    }
}
