import AppKit
import SwiftUI

// MARK: - NSPanel host

/// An NSViewRepresentable that owns the command palette NSPanel.
/// Place this in a .background() so it gets a window reference without affecting layout.
struct CommandPaletteHost: NSViewRepresentable {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore

    func makeCoordinator() -> CommandPaletteController {
        CommandPaletteController()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.attach(to: window, appState: appState, projectStore: projectStore)
        }
        return view
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.setVisible(appState.isCommandPaletteVisible)
    }
}

/// Borderless floating panel that can still become key so SwiftUI receives
/// keyboard events (Esc, arrow keys) and text-field focus.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CommandPaletteController: NSObject {
    private var panel: KeyablePanel?
    private weak var parentWindow: NSWindow?
    private weak var appState: AppState?
    private var clickMonitor: Any?

    func attach(to window: NSWindow, appState: AppState, projectStore: ProjectStore) {
        self.parentWindow = window
        self.appState = appState

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 460),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Panel itself is transparent — the rounded opaque fill comes from the
        // layer-backed hosting view. This lets the corners clip cleanly.
        let bgNSColor = GhosttyApp.shared.backgroundColor
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = CommandPalettePanel()
            .environment(appState)
            .environment(projectStore)
        let hosting = NSHostingView(rootView: content)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = bgNSColor.cgColor
        hosting.layer?.cornerRadius = 12
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting

        self.panel = panel
        // Do NOT addChildWindow here — that would order it on screen immediately.
        // We add it (and remove it) in setVisible so the panel only appears
        // when the palette is explicitly opened.
    }

    func setVisible(_ visible: Bool) {
        guard let panel, let parent = parentWindow else { return }
        if visible {
            positionPanel(panel, in: parent)
            if panel.parent == nil {
                parent.addChildWindow(panel, ordered: .above)
            }
            panel.makeKeyAndOrderFront(nil)
            installClickMonitor()
        } else {
            if panel.parent != nil {
                parent.removeChildWindow(panel)
            }
            panel.orderOut(nil)
            // Hand focus back to the parent window so the terminal receives keys.
            parent.makeKey()
            removeClickMonitor()
        }
    }

    private func positionPanel(_ panel: KeyablePanel, in parent: NSWindow) {
        let parentFrame = parent.frame
        let panelWidth: CGFloat = 500
        // Size the panel to the SwiftUI content's intrinsic height so there's
        // no empty band above or below the search field.
        let fittingSize = panel.contentView?.fittingSize ?? NSSize(width: panelWidth, height: 460)
        let panelHeight = max(fittingSize.height, 80)
        let x = parentFrame.midX - panelWidth / 2
        let titlebarH = parent.frame.height - (parent.contentView?.frame.height ?? 0)
        let contentTop = parentFrame.maxY - titlebarH
        // Position ~15% from the top of the window's content area (matches
        // ghostty's own command palette which sits a bit below the top edge).
        let topOffset = (parent.contentView?.frame.height ?? parentFrame.height) * 0.15
        let y = contentTop - topOffset - panelHeight
        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: false)
    }

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.appState?.isCommandPaletteVisible = false
            }
        }
    }

    private func removeClickMonitor() {
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }
}

// MARK: - View

struct CommandPalettePanel: View {
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
        .background(MactermTheme.bg)
        .overlay(
            RoundedRectangle(cornerRadius: 12).strokeBorder(MactermTheme.border, lineWidth: 1)
        )
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
