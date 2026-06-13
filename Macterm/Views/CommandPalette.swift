import AppKit
import SwiftUI

// MARK: - Overlay

/// A SwiftUI overlay hosting the command palette. Mounts only when visible,
/// dims the background with a click-to-dismiss scrim, and positions the palette
/// ~15% from the top of the available area.
struct CommandPaletteOverlay: View {
    @Environment(AppState.self)
    private var appState

    /// Matches the macOS Tahoe window corner radius so the palette reads as a
    /// native floating surface.
    private static let cornerRadius: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                // Click-outside scrim. Transparent but hit-testable.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.isCommandPaletteVisible = false
                    }

                CommandPalettePanel()
                    .frame(width: 500)
                    .paletteBackground(cornerRadius: Self.cornerRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                            .strokeBorder(MactermTheme.border, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 8)
                    .padding(.top, geo.size.height * 0.15)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private extension View {
    /// Liquid glass on macOS 26; the closest native material on older systems.
    @ViewBuilder
    func paletteBackground(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
        }
    }
}

// MARK: - View

struct CommandPalettePanel: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore

    @State
    private var selectedIndex = 0
    @State
    private var sections: [PaletteSection] = []
    /// Set when the last `selectedIndex` change came from mouse hover, so the
    /// auto-scroll-to-center (keyboard nav) can skip it.
    @State
    private var selectionFromHover = false
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

    /// Coordinate space the results scroll view and row frames share.
    private let rowSpace = "paletteRows"

    /// The search text, stored on `AppState` so it persists across the palette
    /// being closed and reopened. The panel binds to it directly.
    private var query: String {
        get { appState.commandPaletteQuery }
        nonmutating set { appState.commandPaletteQuery = newValue }
    }

    private var queryBinding: Binding<String> {
        Binding(get: { appState.commandPaletteQuery }, set: { appState.commandPaletteQuery = $0 })
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

    private var flatItems: [PaletteItem] { sections.flatMap(\.items) }

    private var placeholderText: String {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.hasPrefix("/") || q.hasPrefix("~") { return "Open directory as new project..." }
        return "Search projects or commands..."
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(MactermTheme.fgMuted)
                TextField(placeholderText, text: queryBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(MactermTheme.fg)
                    .focused($isFieldFocused)
                    .onSubmit { execute() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().background(MactermTheme.border)

            // Results
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
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
                                let idx = flatItems.firstIndex(where: { $0.id == item.id }) ?? 0
                                Button {
                                    selectedIndex = idx
                                    execute()
                                } label: {
                                    CommandPaletteRow(item: item, isSelected: idx == selectedIndex)
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
                          selectedIndex != idx
                    else { return }
                    // Mouse drives selection; suppress the keyboard-nav auto-scroll
                    // below so the list doesn't move under the cursor.
                    selectionFromHover = true
                    selectedIndex = idx
                }
                .onChange(of: selectedIndex) { _, idx in
                    // Only follow keyboard navigation; hovering shouldn't scroll.
                    if selectionFromHover {
                        selectionFromHover = false
                    } else {
                        scrollSelectionIntoView(idx, proxy: proxy)
                    }
                }
            }
        }
        .onAppear {
            // Don't clear `query` — it lives on AppState and is deliberately
            // preserved across close/reopen.
            selectedIndex = 0
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
        .onKeyPress(keys: [.upArrow], phases: [.down, .repeat]) { _ in
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(keys: [.downArrow], phases: [.down, .repeat]) { _ in
            if selectedIndex < flatItems.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "p"), phases: [.down, .repeat]) { press in
            guard press.modifiers == .control else { return .ignored }
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(characters: .init(charactersIn: "n"), phases: [.down, .repeat]) { press in
            guard press.modifiers == .control else { return .ignored }
            if selectedIndex < flatItems.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.tab) {
            completeQuery()
        }
        .onKeyPress(.escape) {
            appState.isCommandPaletteVisible = false
            return .handled
        }
    }

    private func refresh() {
        sections = engine.search(query)
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
        guard !flatItems.isEmpty else { return .ignored }
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

    private func execute() {
        guard selectedIndex >= 0, selectedIndex < flatItems.count else { return }
        let item = flatItems[selectedIndex]
        // Executing a command finishes the task, so the next open should start
        // fresh — only a dismissal (Escape / click-outside) preserves the query.
        query = ""
        appState.isCommandPaletteVisible = false
        item.action()
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

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(MactermTheme.fg)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(MactermTheme.fgMuted)
                        .lineLimit(1)
                }
            }
            Spacer()
            keybindView
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? MactermTheme.fg.opacity(0.12) : .clear)
        // Radius is concentric with the palette container (16) minus the 6pt
        // inset below, so the highlight's curve aligns with the palette's edge.
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 6)
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
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(MactermTheme.fgMuted)
            .frame(minWidth: 16)
            .padding(.vertical, 2)
            .padding(.horizontal, 4)
            .background(MactermTheme.surface, in: .rect(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(MactermTheme.border, lineWidth: 1)
            )
    }
}
