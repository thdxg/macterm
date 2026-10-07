import AppKit
import SwiftUI

// MARK: - Motion

/// The palette's one motion: the pills. A frame pushed or popped comes and
/// goes through SwiftUI's `blurReplace`, the system's own blur-and-scale,
/// on a short curve. The panel itself appears and vanishes in one frame — a
/// view inside the window cannot get the window-level fade and backdrop
/// blur a panel like the quick terminal's gets for free, and a transition
/// drawn in its place read as a slower fade, so it has none.
enum PaletteMotion {
    static var animation: Animation { .easeOut(duration: 0.12) }
    static var transition: BlurReplaceTransition { .blurReplace }
}

// MARK: - Mount

/// Puts the palette over a window while it is visible, in one frame, and
/// takes it away the same way. One place owns this so every window's
/// palette appears the same way.
struct CommandPaletteMount: View {
    let isVisible: Bool

    var body: some View {
        if isVisible {
            CommandPaletteOverlay()
        }
    }
}

// MARK: - Overlay

/// A SwiftUI overlay hosting the command palette. Mounts only when visible,
/// dims the background with a click-to-dismiss scrim, and positions the palette
/// ~15% from the top of the available area.
struct CommandPaletteOverlay: View {
    @Environment(AppState.self)
    private var appState
    /// The palette is a per-window overlay (#345): dismissal closes THIS
    /// window's palette, not whichever window happens to be key.
    @Environment(WindowState.self)
    private var windowState
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    /// Matches the macOS Tahoe window corner radius so the palette reads as a
    /// native floating surface.
    private static let cornerRadius = GlassPanelMetrics.cornerRadius

    var body: some View {
        GeometryReader { geo in
            // The PANEL sits 15% down, with or without screens open: the
            // breadcrumb floats in the space above it, outside the glass, so
            // entering a screen never moves the input or the list, and the
            // panel's own surface never grows.
            let breadcrumb = windowState.paletteStack.isEmpty ? 0 : PaletteBreadcrumb.height + PaletteBreadcrumb.gap
            ZStack(alignment: .top) {
                // Click-outside scrim. Transparent but hit-testable.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        windowState.isCommandPaletteVisible = false
                    }

                VStack(alignment: .leading, spacing: PaletteBreadcrumb.gap) {
                    if !windowState.paletteStack.isEmpty {
                        PaletteBreadcrumb(frames: windowState.paletteStack) { index in
                            windowState.popPaletteFrames(above: index)
                        }
                        .transition(PaletteMotion.transition)
                    }
                    CommandPalettePanel()
                        .glassPanel(cornerRadius: Self.cornerRadius)
                }
                .frame(width: 500)
                .padding(.top, max(0, geo.size.height * 0.15 - breadcrumb))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : PaletteMotion.animation, value: windowState.paletteStack.count)
        }
    }
}

// MARK: - View

struct CommandPalettePanel: View {
    @Environment(AppState.self)
    private var appState
    @Environment(WindowState.self)
    private var windowState
    @Environment(ProjectStore.self)
    private var projectStore

    @State
    private var selectedIndex = 0
    @State
    private var sections: [PaletteSection] = []
    /// The top screen's listing in flight, read off its scope on every
    /// refresh (`PaletteScope.loading`).
    @State
    private var loading: PaletteLoading?
    /// The top screen's failed listing, likewise (`PaletteScope.failure`).
    @State
    private var failure: PaletteFailure?
    /// Knows which `selectedIndex` changes came from mouse hover, so the
    /// auto-scroll-to-center (keyboard nav) can skip them.
    @State
    private var hoverTracker = HoverSelectionTracker()
    /// Each row's vertical extent in the `rowSpace` coordinate space (relative
    /// to the scroll viewport), keyed by flat index. Drives hover-to-select and
    /// edge-only keyboard scrolling.
    @State
    private var rowFrames: [Int: ClosedRange<CGFloat>] = [:]
    /// Height of the results scroll viewport, for deciding when a row is
    /// off-screen and needs scrolling into view.
    @State
    private var viewportHeight: CGFloat = 0
    @FocusState
    private var isFieldFocused: Bool
    /// Whether Option is down, for the rows' alt-action display only: what
    /// runs is decided from the Return or click event itself, so a missed
    /// key-up can never run the wrong action.
    @State
    private var optionHeld = false
    /// Modifier changes and Backspace, watched at the event level while the
    /// palette is up (`PaletteEventMonitor`).
    @State
    private var eventMonitor: PaletteEventMonitor?

    /// Coordinate space the results scroll view and row frames share.
    private let rowSpace = "paletteRows"

    /// The search text, stored on `AppState` so it persists across the palette
    /// being closed and reopened. The panel binds to it directly.
    private var query: String {
        get { appState.commandPaletteQuery }
        nonmutating set { appState.commandPaletteQuery = newValue }
    }

    /// Sources are stateless structs, so rebuilding the engine per render is fine.
    private var engine: PaletteEngine {
        let context = PaletteContext(appState: appState, projectStore: projectStore)
        return PaletteEngine(
            sources: [ProjectSource(), CommandSource()],
            context: context,
            pathSource: DirectorySource()
        )
    }

    /// The palette screen showing, nil for the root (`PaletteScope`). The
    /// instance is the top frame's, kept for as long as the frame is up.
    private var scope: (any PaletteScope)? { windowState.paletteStack.last?.scope }

    private var flatItems: [PaletteItem] { sections.flatMap(\.items) }

    /// `PaletteItem.id → flat index`, built once per body build. Replaces the
    /// per-row `flatItems.firstIndex(where:)` (O(n) over a freshly-flattened
    /// array each call → O(n²) across all rows).
    private var flatIndexByID: [String: Int] {
        Dictionary(flatItems.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }

    private var placeholderText: String {
        if let scope { return scope.placeholder }
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.hasPrefix("/") || q.hasPrefix("~") { return "Open directory as new project..." }
        return "Search projects or commands..."
    }

    var body: some View {
        // Bind the search field to the @Observable AppState via @Bindable
        // rather than a hand-rolled Binding(get:set:).
        @Bindable var appState = appState
        return VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(MactermTheme.fgMuted)
                TextField(placeholderText, text: $appState.commandPaletteQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(MactermTheme.fg)
                    .focused($isFieldFocused)
                // A screen refreshing rows it already shows spins here; one
                // with no rows yet spins in the list instead (one spinner).
                if loading != nil, !sections.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(height: PaletteScopePill.height)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().background(MactermTheme.border)

            // Results
            ScrollViewReader { proxy in
                // Build the id→index map ONCE per body, not per row.
                let indexByID = flatIndexByID
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // A screen's notices: centered in the results, and
                        // filling them when there are no rows — a compact
                        // strip above rows an earlier listing left.
                        if let failure {
                            PaletteFailureNotice(failure: failure) { scope?.retry() }
                                .frame(maxWidth: .infinity, minHeight: sections.isEmpty ? viewportHeight : 0)
                        }
                        if sections.isEmpty, failure == nil, let loading {
                            PaletteLoadingNotice(loading: loading)
                                .frame(maxWidth: .infinity, minHeight: viewportHeight)
                        }
                        ForEach(Array(sections.enumerated()), id: \.offset) { sectionIndex, section in
                            if let header = section.header {
                                Text(header)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(MactermTheme.fgDim)
                                    .padding(.horizontal, 14)
                                    .padding(.top, sectionIndex == 0 ? 8 : 12)
                                    .padding(.bottom, 4)
                            }
                            ForEach(section.items) { item in
                                let idx = indexByID[item.id] ?? 0
                                Button {
                                    selectedIndex = idx
                                    execute(alt: NSEvent.modifierFlags.contains(.option))
                                } label: {
                                    CommandPaletteRow(item: item, isSelected: idx == selectedIndex, optionHeld: optionHeld)
                                }
                                .buttonStyle(.plain)
                                .id(idx)
                                // Publish each row's Y-extent so a single hover
                                // region on the ScrollView can map the pointer to
                                // a row. Per-row tracking areas (`.onHover` /
                                // `.onContinuousHover`) lag on fast pointer motion;
                                // one region with geometry mapping does not.
                                .background(
                                    GeometryReader { geo in
                                        let frame = geo.frame(in: .named(rowSpace))
                                        Color.clear.preference(
                                            key: RowFramesKey.self,
                                            value: [idx: frame.minY ... frame.maxY]
                                        )
                                    }
                                )
                            }
                        }
                    }
                    // Match the rows' 6pt horizontal inset so the gap above
                    // the first row and below the last equals the side spacing.
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 340)
                .coordinateSpace(name: rowSpace)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { viewportHeight = geo.size.height }
                            .onChange(of: geo.size.height) { _, h in viewportHeight = h }
                    }
                )
                .onPreferenceChange(RowFramesKey.self) { rowFrames = $0 }
                .onContinuousHover(coordinateSpace: .named(rowSpace)) { phase in
                    guard case let .active(point) = phase,
                          let idx = rowFrames.first(where: { $0.value.contains(point.y) })?.key,
                          // Mouse drives selection; the tracker lets the
                          // keyboard-nav auto-scroll below skip this change so
                          // the list doesn't move under the cursor.
                          hoverTracker.noteHover(over: idx, current: selectedIndex)
                    else { return }
                    selectedIndex = idx
                }
                .onChange(of: selectedIndex) { _, idx in
                    // Only follow keyboard navigation; hovering shouldn't scroll.
                    guard !hoverTracker.isHoverSelection(idx) else { return }
                    scrollSelectionIntoView(idx, proxy: proxy)
                }
            }
        }
        .onAppear {
            // Don't clear `query` — it lives on AppState and is deliberately
            // preserved across close/reopen.
            selectedIndex = 0
            optionHeld = NSEvent.modifierFlags.contains(.option)
            eventMonitor = PaletteEventMonitor(
                onFlags: { optionHeld = $0.contains(.option) },
                onBackspace: { isRepeat in
                    // Backspace with nothing left to delete steps out of a
                    // screen — on a fresh press only: a Backspace held down
                    // to clear the input stops at the empty field instead of
                    // running on out of the screen.
                    guard windowState.paletteScope != nil, query.isEmpty, !isRepeat else { return false }
                    leaveScope()
                    return true
                }
            )
            appState.customPalettes.reloadIfChanged()
            activateScope()
            refresh()
            // Defer focus to the next runloop so the TextField has been created.
            DispatchQueue.main.async {
                isFieldFocused = true
                // Select the preserved text so a fresh keystroke replaces it
                // while arrows/edits still work — Spotlight/Raycast behavior.
                selectFieldText()
            }
        }
        .onChange(of: query) {
            selectedIndex = 0
            refresh()
        }
        .onChange(of: windowState.paletteStack) {
            selectedIndex = 0
            activateScope()
            refresh()
        }
        .onKeyPress(keys: [.upArrow], phases: [.down, .repeat]) { _ in
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(keys: [.downArrow], phases: [.down, .repeat]) { _ in
            moveSelection(1)
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "p"), phases: [.down, .repeat]) { press in
            guard press.modifiers == .control else { return .ignored }
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "n"), phases: [.down, .repeat]) { press in
            guard press.modifiers == .control else { return .ignored }
            moveSelection(1)
            return .handled
        }
        .onDisappear {
            eventMonitor = nil
            optionHeld = false
        }
        // Return runs the selected row — with ⌥, its alt action. Read off
        // the press rather than `optionHeld`, which is display state.
        .onKeyPress(keys: [.return]) { press in
            execute(alt: press.modifiers.contains(.option))
            return .handled
        }
        .onKeyPress(.tab) {
            completeQuery()
        }
        // ⌘R runs a screen's listing again. Rename Tab's chord, but the app
        // responder stands aside while the palette is up, and on the root
        // it stays ignored.
        .onKeyPress(characters: .init(charactersIn: "r")) { press in
            guard press.modifiers == .command, let scope else { return .ignored }
            scope.retry()
            return .handled
        }
        .onKeyPress(.escape) {
            if windowState.paletteScope != nil {
                leaveScope()
            } else {
                windowState.isCommandPaletteVisible = false
            }
            return .handled
        }
    }

    /// Tell the top screen it is showing (`PaletteScope.activate`); its
    /// redraws come back through `refresh`. Idempotent on the scope's side,
    /// so a frame that returns to the top after a pop is simply told again.
    private func activateScope() {
        guard let scope else { return }
        let context = PaletteContext(appState: appState, projectStore: projectStore)
        scope.activate(context: context) { refresh() }
    }

    private func refresh() {
        if let scope {
            let context = PaletteContext(appState: appState, projectStore: projectStore)
            sections = scope.sections(for: PaletteQuery(raw: query), context: context)
            loading = scope.loading
            failure = scope.failure
        } else {
            sections = engine.search(query)
            loading = nil
            failure = nil
        }
        // Never rest the selection on a muted row (e.g. when it's the top
        // match after a query change).
        if flatItems.indices.contains(selectedIndex), !flatItems[selectedIndex].isEnabled,
           let firstEnabled = flatItems.indices.first(where: { flatItems[$0].isEnabled })
        {
            selectedIndex = firstEnabled
        }
    }

    /// Step the keyboard selection by `delta`, skipping disabled rows so
    /// Enter can never land on one. When only disabled rows remain in that
    /// direction, the selection stays put.
    private func moveSelection(_ delta: Int) {
        var idx = selectedIndex + delta
        while idx >= 0, idx < flatItems.count, !flatItems[idx].isEnabled {
            idx += delta
        }
        if idx >= 0, idx < flatItems.count {
            selectedIndex = idx
        }
    }

    /// Select all text in the focused search field via the window's field
    /// editor, so reopening the palette with a preserved query highlights it.
    private func selectFieldText() {
        guard !query.isEmpty,
              let window = NSApp.keyWindow,
              let editor = window.fieldEditor(false, for: nil)
        else { return }
        editor.selectAll(nil)
    }

    /// Tab autocompletes the input with the top result. Commands and projects
    /// complete to their title; in path mode the directory item completes to its
    /// full path (with a trailing slash) so a second Tab descends into it. Does
    /// nothing when the query is empty or the completion wouldn't change the
    /// input — letting the keypress fall through (`.ignored`) to default focus
    /// traversal in that case.
    private func completeQuery() -> KeyPress.Result {
        // A scope's rows aren't completions of what is typed (its add rows
        // quote the query back), so Tab keeps its focus meaning there.
        guard scope == nil, !flatItems.isEmpty else { return .ignored }
        let top = flatItems[0]
        let completion: String = if let path = directoryPath(for: top) {
            // Re-expand a `~` query to keep the displayed prefix the user typed.
            query.hasPrefix("~") ? abbreviateTilde(path) : path
        } else {
            top.title
        }
        guard completion != query else { return .ignored }
        query = completion
        return .handled
    }

    /// Full path a directory item points at, parsed from its id
    /// (`dir-open:/abs/path` or `dir-switch:/abs/path`). `nil` for non-path items.
    private func directoryPath(for item: PaletteItem) -> String? {
        for prefix in ["dir-open:", "dir-switch:"] where item.id.hasPrefix(prefix) {
            let path = String(item.id.dropFirst(prefix.count))
            return path.hasSuffix("/") ? path : path + "/"
        }
        return nil
    }

    private func abbreviateTilde(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    /// Leading/trailing breathing room kept between the selected row and the
    /// viewport edge when keyboard navigation scrolls it into view.
    private static let scrollPadding: CGFloat = 8

    /// Scroll just enough to reveal `idx` when it sits within `scrollPadding` of
    /// an edge, anchoring it that far in from whichever edge it ran toward. A
    /// row already comfortably inside the viewport is left untouched, so keyboard
    /// navigation nudges the list instead of re-centering on every move. Falls
    /// back to a plain `scrollTo` until the row's geometry is known.
    private func scrollSelectionIntoView(_ idx: Int, proxy: ScrollViewProxy) {
        guard let range = rowFrames[idx], viewportHeight > 0 else {
            proxy.scrollTo(idx)
            return
        }
        let pad = Self.scrollPadding
        // `scrollTo` aligns the row's anchor fraction to the same fraction of the
        // viewport, so anchoring `pad` in from an edge leaves that gap.
        if range.lowerBound < pad {
            proxy.scrollTo(idx, anchor: UnitPoint(x: 0, y: pad / viewportHeight))
        } else if range.upperBound > viewportHeight - pad {
            proxy.scrollTo(idx, anchor: UnitPoint(x: 0, y: 1 - pad / viewportHeight))
        }
        // Otherwise the row is already comfortably visible — leave it alone.
    }

    /// Run the selected row: its alt action when `alt` and it has one, else
    /// its primary action — or enter the screen it opens.
    private func execute(alt: Bool = false) {
        guard selectedIndex >= 0, selectedIndex < flatItems.count else { return }
        let item = flatItems[selectedIndex]
        // A muted row explains why it can't run; Enter on it is a no-op that
        // keeps the palette open (selection normally can't land here — this
        // guards the mouse-hover path).
        guard item.isEnabled else { return }
        if let altAction = item.alt, alt {
            query = ""
            windowState.isCommandPaletteVisible = false
            altAction.action()
            return
        }
        if let next = item.opensScope {
            enterScope(next)
            return
        }
        // Executing a command finishes the task, so the next open should start
        // fresh — only a dismissal (Escape / click-outside) preserves the query.
        query = ""
        windowState.isCommandPaletteVisible = false
        item.action()
    }
}

/// Local monitors for what SwiftUI's `onKeyPress` cannot see while the
/// palette is up: a bare modifier press (for the ⌥ display), and Backspace
/// with its repeat flag — the field editor takes Backspace before the key
/// press reaches the hierarchy, and `onKeyPress`'s `phases:` filter does
/// not see it at all. Removed when the palette goes.
private final class PaletteEventMonitor {
    /// Installed and removed on the main thread; `deinit` is nonisolated
    /// under Swift 6, hence the unchecked storage.
    nonisolated(unsafe) private var tokens: [Any] = []

    /// `onBackspace` is handed whether the press is an auto-repeat and
    /// returns whether it consumed the key.
    @MainActor
    init(onFlags: @escaping @MainActor (NSEvent.ModifierFlags) -> Void, onBackspace: @escaping @MainActor (Bool) -> Bool) {
        if let flags = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            MainActor.assumeIsolated { onFlags(event.modifierFlags.intersection(.deviceIndependentFlagsMask)) }
            return event
        }) {
            tokens.append(flags)
        }
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            guard event.keyCode == 51, event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return event }
            return MainActor.assumeIsolated { onBackspace(event.isARepeat) } ? nil : event
        }) {
            tokens.append(keys)
        }
    }

    deinit {
        for token in tokens {
            NSEvent.removeMonitor(token)
        }
    }
}

private extension CommandPalettePanel {
    /// Show `next` over the screen showing, starting from an empty query.
    /// The text isn't kept: it was the search that found the way in.
    func enterScope(_ next: PaletteScopeID) {
        query = ""
        windowState.pushPaletteFrame(PaletteFrame(next))
    }

    /// Back one screen, starting its search empty.
    func leaveScope() {
        query = ""
        windowState.popPaletteFrame()
    }
}

// MARK: - Breadcrumb

/// The screens open, as a row of pills floating above the panel, root
/// first: Finder's path bar in miniature, outside the glass rather than in
/// it — a nested palette needs several pills, the input's width is the
/// search's, and the panel's surface stays the panel's. The current
/// screen's pill is drawn in full and takes the width first; its ancestors
/// are muted, shrink first (middle-truncated) and pop the stack back to
/// themselves when clicked. The row never outgrows the panel: a current
/// pill named by a long row title truncates in the middle rather than
/// pushing the panel off its anchor.
struct PaletteBreadcrumb: View {
    /// The row's height — what the overlay lifts the panel's anchor by,
    /// with `gap`, so it must be exact.
    static let height: CGFloat = PaletteScopePill.height
    /// Between the pills and the panel's top edge.
    static let gap: CGFloat = 8

    let frames: [PaletteFrame]
    let popTo: (Int) -> Void

    var body: some View {
        pills
            .frame(height: Self.height, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var pills: some View {
        if #available(macOS 26.0, *), WindowAppearance.glassSupported {
            GlassEffectContainer { row }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(MactermTheme.fgMuted)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .transition(PaletteMotion.transition)
                }
                let isCurrent = index == frames.count - 1
                Button {
                    popTo(index)
                } label: {
                    PaletteScopePill(pill: frame.pill, isCurrent: isCurrent)
                }
                .buttonStyle(.plain)
                .disabled(isCurrent)
                .layoutPriority(isCurrent ? 1 : 0)
                // A frame pushed or popped comes and goes as the panel does.
                .transition(PaletteMotion.transition)
            }
        }
    }
}

/// One frame's pill: liquid glass on macOS 26 where the window draws glass,
/// the panel's material otherwise — it floats over the terminal, so the
/// theme's translucent surface alone would vanish into it — with the
/// panel's hairline and a shadow of its own.
private struct PaletteScopePill: View {
    /// The pill's height, and the palette input row's.
    static let height: CGFloat = 22

    let pill: PalettePill
    let isCurrent: Bool

    var body: some View {
        Label(pill.title, systemImage: pill.systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isCurrent ? MactermTheme.fg : MactermTheme.fgMuted)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 9)
            .frame(height: Self.height)
            .modifier(PillBackground())
    }

    private struct PillBackground: ViewModifier {
        func body(content: Content) -> some View {
            if #available(macOS 26.0, *), WindowAppearance.glassSupported {
                content
                    .glassEffect(.regular, in: .capsule)
                    .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 3)
            } else {
                content
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(MactermTheme.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 3)
            }
        }
    }
}

// MARK: - Loading

/// The results while a screen's first listing is in flight: a spinner and
/// what it waits on, centered.
private struct PaletteLoadingNotice: View {
    let loading: PaletteLoading

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(loading.message)
                .font(.system(size: 13))
                .foregroundStyle(MactermTheme.fgMuted)
                .lineLimit(1)
        }
        .padding(20)
    }
}

/// A screen's listing that failed: the failure color's warning glyph, what
/// failed over why, and Retry, centered. Not a result row — it is never
/// selected and Enter never lands on it — so it is a notice.
private struct PaletteFailureNotice: View {
    let failure: PaletteFailure
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(MactermTheme.failure)
            Text(failure.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MactermTheme.fg)
            if let detail = failure.detail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(MactermTheme.fgMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            Button("Retry", action: retry)
                .controlSize(.small)
                .padding(.top, 4)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 20)
    }
}

// MARK: - Hover geometry

/// Collects each result row's vertical extent (keyed by flat index) so a single
/// hover region can map the pointer to a row, avoiding per-row tracking areas
/// that lag on fast pointer motion.
private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [Int: ClosedRange<CGFloat>] = [:]
    static func reduce(value: inout [Int: ClosedRange<CGFloat>], nextValue: () -> [Int: ClosedRange<CGFloat>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Row

private struct CommandPaletteRow: View {
    let item: PaletteItem
    let isSelected: Bool
    /// Option is down: a row with an alt action shows that action's title
    /// in place of its subtitle and drops its keybind caps — the chord is
    /// implied by the key being held.
    let optionHeld: Bool

    private var showsAlt: Bool { optionHeld && item.alt != nil }

    var body: some View {
        HStack(spacing: 8) {
            if let icon = item.icon {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(item.isEnabled ? MactermTheme.fgMuted : MactermTheme.fgDim)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(highlightedTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(item.isEnabled ? MactermTheme.fg : MactermTheme.fgDim)
                if let subtitle = showsAlt ? item.alt?.title : item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(item.isEnabled ? MactermTheme.fgMuted : MactermTheme.fgDim)
                        .lineLimit(1)
                }
            }
            // At least a key-cap tall, so a row with a keybind and one
            // without measure the same (the caps outgrow a single title line).
            .frame(minHeight: KeyCap.height)
            Spacer()
            if !showsAlt {
                keybindView
            }
            if let warning = item.warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(MactermTheme.failure)
                    .help(warning)
            }
            // A way into a screen, not a thing to do.
            if item.opensScope != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MactermTheme.fgDim)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? MactermTheme.fg.opacity(0.12) : .clear)
        // Radius is concentric with the palette container (16) minus the 6pt
        // inset below, so the highlight's curve aligns with the palette's edge.
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 6)
    }

    /// The title with the characters the query matched in semibold — what
    /// `Search` lined up, so the user sees why a row ranked where it did.
    private var highlightedTitle: AttributedString {
        guard !item.highlights.isEmpty else { return AttributedString(item.title) }
        let matched = Set(item.highlights)
        var out = AttributedString()
        var run = ""
        var runMatched = false
        var offset = 0
        func flush() {
            guard !run.isEmpty else { return }
            var part = AttributedString(run)
            if runMatched { part.font = .system(size: 13, weight: .semibold) }
            out += part
            run = ""
        }
        for character in item.title {
            // A character is matched when any of its scalars was.
            let scalars = character.unicodeScalars.count
            let isMatched = (offset ..< offset + scalars).contains { matched.contains($0) }
            if isMatched != runMatched {
                flush()
                runMatched = isMatched
            }
            run.append(character)
            offset += scalars
        }
        flush()
        return out
    }

    @ViewBuilder
    private var keybindView: some View {
        if let symbols = item.keybindSymbols {
            HStack(spacing: 4) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, sym in
                    KeyCap(symbol: sym)
                }
            }
        } else if let keybind = item.keybind {
            // Defensive fallback: an item with a joined keybind but no split
            // symbols (command items always supply symbols).
            Text(keybind)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(MactermTheme.fgDim)
        }
    }
}

/// A single rounded key-cap, e.g. `⌘` or `Tab`, rendered Raycast-style.
private struct KeyCap: View {
    /// Every cap's height, and the floor of every row's text column.
    static let height: CGFloat = 18

    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(MactermTheme.fgMuted)
            .frame(minWidth: 16)
            .frame(height: Self.height)
            .padding(.horizontal, 4)
            .background(MactermTheme.surface, in: .rect(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(MactermTheme.border, lineWidth: 1)
            )
    }
}
