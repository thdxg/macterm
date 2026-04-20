import AppKit
import SwiftUI

// MARK: - View

struct CommandPaletteOverlay: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore

    var body: some View {
        if appState.isCommandPaletteVisible {
            ZStack {
                Color.black.opacity(0.01)
                    .ignoresSafeArea()
                    .onTapGesture { appState.isCommandPaletteVisible = false }

                VStack {
                    CommandPalettePanel()
                        .frame(width: 500)
                        .padding(.top, 80)
                    Spacer()
                }
            }
            .transition(.opacity)
        }
    }
}

private struct CommandPalettePanel: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore

    @State
    private var query = ""
    @State
    private var selectedIndex = 0
    @State
    private var sections: [PaletteSection] = []
    @FocusState
    private var isFieldFocused: Bool

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
                TextField(placeholderText, text: $query)
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
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 340)
                .onChange(of: selectedIndex) { _, idx in
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MactermTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
        .onAppear {
            query = ""
            selectedIndex = 0
            refresh()
            // Defer focus to the next runloop so the TextField has been created.
            DispatchQueue.main.async { isFieldFocused = true }
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
        .onKeyPress(.escape) {
            appState.isCommandPaletteVisible = false
            return .handled
        }
    }

    private func refresh() {
        sections = engine.search(query)
    }

    private func execute() {
        guard selectedIndex >= 0, selectedIndex < flatItems.count else { return }
        let item = flatItems[selectedIndex]
        appState.isCommandPaletteVisible = false
        item.action()
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
            if let keybind = item.keybind {
                Text(keybind)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(MactermTheme.fgDim)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(isSelected ? MactermTheme.surface : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
    }
}
