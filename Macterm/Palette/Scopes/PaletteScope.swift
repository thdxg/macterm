import Foundation

/// An alternate screen of the command palette: one search over one kind of
/// thing, entered from a root item or straight from its `AppCommand`. The
/// screens showing form a stack (`WindowState.paletteStack`), drawn as a
/// row of pills above the input — one per frame, the current one last —
/// so a screen can open another and the way back stays visible. Backspace
/// on an empty query or Escape pop one frame; clicking a pill pops back to
/// it; running an item closes the palette as usual.
///
/// A new built-in scope is a case here, with its pill, plus a class
/// conforming to `PaletteScope` in `Palette/Scopes/`; an `AppCommand` opens
/// it by returning the case from `paletteScope`, which is what turns its
/// palette row into a way in rather than a command. Built-in scopes are
/// Swift because their listings are in-process reads (the keychain, git's
/// files) that a shell command could only approximate slowly or not at all.
/// A custom palette (`CustomPaletteFile`, a YAML file of nodes) is the one
/// `.custom` case, its screens told apart by `CustomPaletteTarget`.
enum PaletteScopeID: Hashable {
    case passwords
    case worktrees
    case files
    /// A screen of a custom palette (`CustomPaletteFile`): its file, node,
    /// the values exported above it and the pill naming it.
    case custom(CustomPaletteTarget)

    /// The screens Macterm ships, in Settings → Palettes order.
    static let builtIn: [PaletteScopeID] = [.passwords, .worktrees, .files]

    /// What the scope's pill says and shows — also the icon of the row that
    /// opens it, so the row reads as a place to go rather than a thing to do.
    var pill: PalettePill {
        switch self {
        case .passwords: PalettePill(title: "Password Manager", systemImage: "key.fill")
        case .worktrees: PalettePill(title: "Worktrees", systemImage: "arrow.triangle.branch")
        case .files: PalettePill(title: "Files", systemImage: "doc.text.magnifyingglass")
        case let .custom(target): target.pill
        }
    }

    /// One line for Settings → Palettes: what the screen lists.
    var summary: String {
        switch self {
        case .passwords: "Your saved passwords, typed into the focused pane when picked."
        case .worktrees: "The project's linked git worktrees, each opening a new tab there."
        case .files: "The project's files and directories by partial path, opened in a split; ⌥ opens with the default app."
        case .custom: ""
        }
    }

    /// The command that opens a built-in screen — its title, chord and menu
    /// item. A custom palette has none: its chord is `PaletteHotkeys`'.
    var command: AppCommand? {
        switch self {
        case .passwords: .passwordManager
        case .worktrees: .worktrees
        case .files: .files
        case .custom: nil
        }
    }

    /// The id Settings → Palettes' switch stores
    /// (`Preferences.disabledPaletteIDs`): a built-in by name, a custom
    /// palette by its file — every node of it shares the one switch.
    var settingsID: String {
        switch self {
        case .passwords: "passwords"
        case .worktrees: "worktrees"
        case .files: "files"
        case let .custom(target): Self.customSettingsID(paletteID: target.paletteID)
        }
    }

    static func customSettingsID(paletteID: String) -> String {
        "custom:\(paletteID)"
    }

    /// Settings → Palettes. Off, the screen leaves the palette and its menu.
    @MainActor
    var isEnabled: Bool {
        Preferences.shared.isPaletteEnabled(settingsID)
    }

    @MainActor
    func makeScope() -> any PaletteScope {
        switch self {
        case .passwords: PasswordPaletteScope()
        case .worktrees: WorktreesPaletteScope()
        case .files: FilesPaletteScope()
        case let .custom(target): CustomPaletteScope(target: target)
        }
    }
}

/// A pill in the breadcrumb above the input: a frame's name and glyph.
struct PalettePill: Hashable {
    let title: String
    let systemImage: String
}

/// A listing in flight: what the scope is waiting on, shown with a spinner
/// in the results while the screen has no rows yet, and in the input's
/// trailing edge while it refreshes rows already up.
struct PaletteLoading: Equatable {
    let message: String
}

/// A listing that failed — a command not found, exiting non-zero, or
/// printing something that isn't the shape asked for. Shown as a row at
/// the top of the results, above any rows an earlier listing left, with
/// Retry (`PaletteScope.retry`, also ⌘R). `detail` is the reason as the
/// user can act on it: the command's stderr, or where the output stopped
/// parsing.
struct PaletteFailure: Error, Equatable {
    let title: String
    let detail: String?

    init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }
}

/// One screen's logic. A scope is a class so a frame can keep it for as
/// long as it is on the stack: a scope whose listing takes time (a command's
/// output) loads it once in `activate`, reports `loading` meanwhile, caches
/// the rows and filters them per keystroke in `sections`. The built-in
/// scopes read live, in-process state and need none of that.
@MainActor
protocol PaletteScope: AnyObject {
    var placeholder: String { get }
    /// Every section for `query`, in display order. Unlike the root's merged
    /// search, a scope keeps its own sections while searching — its
    /// matches, then whatever it offers to do with the text typed.
    func sections(for query: PaletteQuery, context: PaletteContext) -> [PaletteSection]

    /// A listing in flight, nil when nothing is. Read after every
    /// `onChange` the scope reports and on every `sections` call.
    var loading: PaletteLoading? { get }
    /// The last listing's failure, nil when it succeeded or none has run.
    /// Cleared when a retry starts.
    var failure: PaletteFailure? { get }
    /// Run the listing again after a failure — the failure row's button and
    /// ⌘R. Nothing for a scope that never fails.
    func retry()
    /// The frame has become the screen showing. Start any listing here and
    /// call `onChange` (on the main actor) whenever `loading` or what
    /// `sections` would return has changed, so the palette redraws. Called
    /// again whenever the frame becomes the top of the stack, so it must be
    /// idempotent — a listing already loaded or in flight is left alone.
    func activate(context: PaletteContext, onChange: @escaping @MainActor () -> Void)
    /// The frame has left the stack: cancel anything in flight.
    func deactivate()
}

extension PaletteScope {
    var loading: PaletteLoading? { nil }
    var failure: PaletteFailure? { nil }
    func retry() {}
    func activate(context _: PaletteContext, onChange _: @escaping @MainActor () -> Void) {}
    func deactivate() {}
}

/// A screen on the palette's stack: which scope, the pill naming it, and
/// the scope instance that lives as long as the frame does. Two frames of
/// one scope can be on the stack at once (a nested palette entered through
/// two selections), so identity is the frame's own token, not the scope.
@MainActor
struct PaletteFrame: Equatable, Identifiable {
    let id = UUID()
    let scopeID: PaletteScopeID
    let pill: PalettePill
    let scope: any PaletteScope

    /// A frame for `scopeID`, named by its own pill unless `pill` says
    /// otherwise — a nested screen is named by the row that opened it.
    /// `scope` stands in for the one `scopeID` would make (tests).
    init(_ scopeID: PaletteScopeID, pill: PalettePill? = nil, scope: (any PaletteScope)? = nil) {
        self.scopeID = scopeID
        self.pill = pill ?? scopeID.pill
        self.scope = scope ?? scopeID.makeScope()
    }

    nonisolated static func == (lhs: PaletteFrame, rhs: PaletteFrame) -> Bool {
        lhs.id == rhs.id
    }
}
