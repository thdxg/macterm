import Foundation

/// A bundled AI coding-agent logo, matched from a pane's live foreground
/// process so the sidebar shows *which* agent runs in a tab instead of the
/// generic tab icon. The raw value is the asset-catalog image name (a
/// monochrome template image, tinted like an SF Symbol).
enum AgentIcon: String, CaseIterable {
    case claude = "AgentClaude"
    case codex = "AgentCodex"
    case opencode = "AgentOpenCode"
    case cursor = "AgentCursor"
    case gemini = "AgentGemini"
    case copilot = "AgentCopilot"
    case grok = "AgentGrok"
    case pi = "AgentPi"

    /// Agent CLI names, matched against a process's kernel `comm` (the
    /// executable's basename, truncated to 15 chars) and its invoked name
    /// (argv-derived). Both are needed: an agent's *binary* often isn't named
    /// after the CLI — brew's codex is `codex-aarch64-apple-darwin` (comm
    /// `codex-aarch64-a`), and Claude Code's native install execs a versioned
    /// binary whose comm is the bare version (`2.1.207`) while argv[0] stays
    /// `claude`. Internal (not private) so a guard test can assert every case
    /// keeps a mapping here.
    static let processNames: [String: AgentIcon] = [
        "claude": .claude,
        "codex": .codex,
        "opencode": .opencode,
        "cursor-agent": .cursor,
        "gemini": .gemini,
        "copilot": .copilot,
        "grok": .grok,
        "pi": .pi,
    ]

    /// The agent running as `processName`, or nil for anything else
    /// (shells, ordinary programs, nil before the surface exists). An exact
    /// match wins; otherwise a known name followed by a non-alphanumeric
    /// separator matches (`codex-aarch64-a` → codex), so arch/version suffixes
    /// don't defeat detection while `claudette` still doesn't match `claude`.
    static func match(processName: String?) -> AgentIcon? {
        guard let name = processName?.lowercased() else { return nil }
        if let exact = processNames[name] { return exact }
        // Longest key first, so a future short alias that prefixes a longer
        // name can't win by nondeterministic dictionary order.
        for (key, icon) in processNames.sorted(by: { $0.key.count > $1.key.count }) where name.hasPrefix(key) {
            if let next = name.dropFirst(key.count).first, !next.isLetter, !next.isNumber {
                return icon
            }
        }
        return nil
    }

    /// Match against the kernel `comm` first (already in hand from the poll),
    /// falling back to the argv-derived invoked name. The fallback is read
    /// lazily and ONLY when `comm` cannot name the CLI itself: an opaque
    /// versioned binary (Claude Code's native install) or an interpreter
    /// (npm-installed CLIs run as `node script`). A real process name that
    /// simply isn't an agent (bash, hx, btop…) must not cost a
    /// `KERN_PROCARGS2` read on the default poll.
    static func match(comm: String?, argv0 fallback: () -> String?) -> AgentIcon? {
        if let icon = match(processName: comm) { return icon }
        if let comm {
            guard ProcessInspector.looksLikeVersionString(comm)
                || ProcessInspector.isInterpreterName(comm)
            else { return nil }
        }
        return match(processName: fallback())
    }
}
