import Foundation

/// What the palette knows about the current session when asking sources for items.
/// Sources read this instead of poking globals directly, so they're easier to
/// reason about.
@MainActor
struct PaletteContext {
    let appState: AppState
    let projectStore: ProjectStore
}

/// A selectable palette item. Same shape as the old `CommandPaletteItem`
/// with an explicit `score` so the engine can rank-merge across sources.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let category: String?
    let keybind: String?
    /// The keybind split into individual glyphs (e.g. `["⇧", "⌘", "A"]`) so the
    /// row can render each as its own key-cap. `nil` when the item has no
    /// keybind. Mirrors `keybind`, which keeps the joined form.
    let keybindSymbols: [String]?
    /// Lower is better. 0 = exact prefix match, ~5 = substring, ~40 = subsequence.
    let score: Int
    /// A disabled item renders muted, is skipped by keyboard selection, and
    /// never executes — visible so the user learns *why* it's unavailable
    /// (the subtitle carries the reason) instead of wondering where it went.
    let isEnabled: Bool
    let action: () -> Void

    init(
        id: String? = nil,
        title: String,
        subtitle: String? = nil,
        category: String? = nil,
        keybind: String? = nil,
        keybindSymbols: [String]? = nil,
        score: Int = 1,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.id = id ?? "\(category ?? "")/\(title)"
        self.title = title
        self.subtitle = subtitle
        self.category = category
        self.keybind = keybind
        self.keybindSymbols = keybindSymbols
        self.score = score
        self.isEnabled = isEnabled
        self.action = action
    }

    /// A copy with a new `score`, carrying every other field forward. Sources
    /// that re-score a prebuilt item on query use this so a newly-added field
    /// (e.g. `isEnabled`) can't be silently dropped to its default by a
    /// hand-copied initializer call.
    func with(score: Int) -> PaletteItem {
        PaletteItem(
            id: id,
            title: title,
            subtitle: subtitle,
            category: category,
            keybind: keybind,
            keybindSymbols: keybindSymbols,
            score: score,
            isEnabled: isEnabled,
            action: action
        )
    }
}

struct PaletteSection {
    let header: String?
    let items: [PaletteItem]
}

struct PaletteQuery {
    let raw: String
    var trimmed: String { raw.trimmingCharacters(in: .whitespaces) }
    var isEmpty: Bool { trimmed.isEmpty }
    var looksLikePath: Bool {
        trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || Self.isRemoteSpecQuery(trimmed)
    }

    /// A typed `[user@]host:dir` spec — the remote analogue of a typed local
    /// path (#104). Deliberately STRICTER than `ProjectPath.parse`: path mode
    /// short-circuits the whole palette, so any `word:word` must not swallow
    /// a command query. Requires no whitespace, a hostname-shaped host, and
    /// a `~`- or `/`-anchored directory (a relative remote dir is valid in a
    /// project file, but too ambiguous to hijack the palette for).
    static func isRemoteSpecQuery(_ query: String) -> Bool {
        guard !query.contains(where: \.isWhitespace),
              case let .remote(_, host, directory)? = ProjectPath.remote(from: query),
              directory.hasPrefix("~") || directory.hasPrefix("/"),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" })
        else { return false }
        return true
    }
}

/// A pluggable source of palette items. Sources return scored items for a
/// query; the engine merges and ranks them.
@MainActor
protocol PaletteSource {
    /// Items for a non-empty, non-path query. Implementations return items
    /// with `score` populated (use `fuzzyScore`); non-matching items are omitted.
    func items(query: String, context: PaletteContext) -> [PaletteItem]

    /// Items shown when the input is empty. `nil` means "no empty-state items"
    /// (the engine skips this source's empty section).
    func emptyItems(context: PaletteContext) -> [PaletteItem]?
}

/// Composes sources, applies ranking, and returns the final sectioned list.
@MainActor
struct PaletteEngine {
    let sources: [PaletteSource]
    let context: PaletteContext
    /// Consulted only when the query is path-like. On path input, the engine
    /// replaces all sources' output with the path source's output.
    let pathSource: PaletteSource?

    func search(_ raw: String) -> [PaletteSection] {
        let q = PaletteQuery(raw: raw)

        // Path mode: short-circuit to only the path source.
        if q.looksLikePath, let pathSource {
            let items = pathSource.items(query: q.trimmed, context: context)
            return items.isEmpty ? [] : [PaletteSection(header: nil, items: items)]
        }

        if q.isEmpty {
            // Empty state: each source contributes a section. Sources set
            // their own categories (e.g. "Recent", "Tabs", "Panes") — we
            // just group by whatever they set.
            var sections: [PaletteSection] = []
            for source in sources {
                guard let items = source.emptyItems(context: context), !items.isEmpty else { continue }
                sections += groupByCategory(items)
            }
            return sections
        }

        // Active search: merge + rank to one flat list so the best match is
        // always on top regardless of which source produced it.
        var all: [PaletteItem] = []
        for source in sources {
            all += source.items(query: q.trimmed, context: context)
        }
        // Total, deterministic order: score, then title, then id — Swift's
        // `sort` isn't guaranteed stable, so equal scores need explicit
        // tiebreakers rather than relying on incidental input order.
        all.sort { ($0.score, $0.title, $0.id) < ($1.score, $1.title, $1.id) }
        return all.isEmpty ? [] : [PaletteSection(header: nil, items: all)]
    }

    private func groupByCategory(_ items: [PaletteItem]) -> [PaletteSection] {
        var seen = Set<String>()
        var order: [String] = []
        var grouped: [String: [PaletteItem]] = [:]
        for item in items {
            let cat = item.category ?? ""
            if seen.insert(cat).inserted { order.append(cat) }
            grouped[cat, default: []].append(item)
        }
        return order.map { cat in
            PaletteSection(header: cat.isEmpty ? nil : cat, items: grouped[cat] ?? [])
        }
    }
}

// MARK: - Fuzzy

/// Returns a score (lower = better match) or nil if no match.
/// 0 = exact prefix, <10 = substring hit, <50 = subsequence hit.
func fuzzyScore(query: String, target: String) -> Int? {
    let q = query.lowercased()
    let t = target.lowercased()
    guard !q.isEmpty else { return 0 }
    if t.hasPrefix(q) { return 0 }
    if let range = t.range(of: q) {
        // Clamp to just under the subsequence floor (40) so every contiguous
        // substring hit always outranks every scattered subsequence hit, even
        // when the substring sits deep in a long target.
        return min(5 + t.distance(from: t.startIndex, to: range.lowerBound), 39)
    }
    // Subsequence
    var qi = q.startIndex
    for ch in t where ch == q[qi] {
        qi = q.index(after: qi)
        if qi == q.endIndex { return 40 + (t.count - q.count) }
    }
    return nil
}
