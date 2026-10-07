import Foundation

/// An alternate screen of the command palette: one search over one kind of
/// thing, entered from a root item or straight from its `AppCommand`. While
/// a scope is up, a pill at the input's leading edge names it, its own
/// placeholder shows, and its `sections` replace the root's ranked list.
/// Backspace on an empty query or Escape go back to the root; running an item
/// closes the palette as usual.
///
/// A new scope is a case here plus a type conforming to `PaletteScope`; an
/// `AppCommand` opens it by returning the case from `paletteScope`, which is
/// what turns its palette row into a way in rather than a command.
enum PaletteScopeID: String, Hashable {
    case passwords
    case worktrees

    @MainActor
    func makeScope() -> any PaletteScope {
        switch self {
        case .passwords: PasswordPaletteScope()
        case .worktrees: WorktreesPaletteScope()
        }
    }
}

/// The pill a scope shows at the input's leading edge.
struct PalettePill: Equatable {
    let title: String
    let systemImage: String
}

@MainActor
protocol PaletteScope {
    var pill: PalettePill { get }
    var placeholder: String { get }
    /// Every section for `query`, in display order. Unlike the root's merged
    /// search, a scope keeps its own sections while searching — its
    /// matches, then whatever it offers to do with the text typed.
    func sections(for query: PaletteQuery, context: PaletteContext) -> [PaletteSection]
}
