import AppKit
import Carbon
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            QuickTerminalSettings()
                .tabItem { Label("Quick Terminal", systemImage: "rectangle.bottomthird.inset.filled") }
            KeymapSettings()
                .tabItem { Label("Keymaps", systemImage: "keyboard") }
        }
        .frame(width: 520, height: 540)
    }
}

// MARK: - Appearance

private struct ThemePreview: Identifiable, Hashable {
    let id: String
    let background: NSColor
    let foreground: NSColor
    let palette: [NSColor]

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ThemePreview, rhs: ThemePreview) -> Bool {
        lhs.id == rhs.id
    }
}

private struct AppearanceSettings: View {
    @State
    private var themes: [ThemePreview] = []
    @State
    private var currentTheme: String = ""
    @State
    private var currentFont: String = ""
    @State
    private var monoFonts: [String] = []
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GroupBox("Font") {
                    VStack(alignment: .leading, spacing: 8) {
                        settingRow("Font Family") {
                            MonoFontPicker(
                                fonts: monoFonts,
                                selection: $currentFont
                            )
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onChange(of: currentFont) { _, v in
                                if v.isEmpty {
                                    MactermConfig.shared.removeValue("font-family")
                                } else {
                                    MactermConfig.shared.updateValue("font-family", value: v)
                                }
                                GhosttyApp.shared.reloadConfig()
                            }
                        }
                    }
                    .padding(8)
                }
                GroupBox("Theme") {
                    VStack(alignment: .leading, spacing: 8) {
                        settingRow("Select Theme") {
                            Picker("Select Theme", selection: $currentTheme) {
                                Text("Default").tag("")
                                Divider()
                                ForEach(themes) { theme in
                                    Text(theme.id).tag(theme.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .onChange(of: currentTheme) { _, v in
                                MactermConfig.shared.updateValue("theme", value: "\"\(v)\"")
                                GhosttyApp.shared.reloadConfig()
                            }
                        }
                        .pickerStyle(.menu)

                        if let theme = themes.first(where: { $0.id == currentTheme }) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Preview")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                HStack(alignment: .top, spacing: 16) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("BG / FG")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                        HStack(spacing: 6) {
                                            colorChip(theme.background)
                                            colorChip(theme.foreground)
                                        }
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Palette")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                        LazyVGrid(
                                            columns: Array(repeating: GridItem(.fixed(16), spacing: 4, alignment: .leading), count: 8),
                                            alignment: .leading,
                                            spacing: 4
                                        ) {
                                            ForEach(Array(theme.palette.enumerated()), id: \.offset) { _, color in
                                                colorChip(color)
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(8)
                }
            }
            .padding(16)
        }
        .task { await loadThemes() }
        .onAppear {
            loadCurrentValues()
            monoFonts = Self.loadMonoFonts()
        }
    }

    private func settingRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).frame(width: 100, alignment: .leading)
            content()
        }
    }

    private func loadCurrentValues() {
        currentTheme = MactermConfig.shared.value(for: "theme")?.replacingOccurrences(of: "\"", with: "") ?? ""
        currentFont = MactermConfig.shared.value(for: "font-family") ?? ""
    }

    private static func loadMonoFonts() -> [String] {
        NSFontManager.shared
            .availableFontFamilies
            .filter { family in
                guard let font = NSFont(name: family, size: 13) else { return false }
                return font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func loadThemes() async {
        let paths = [
            "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
            NSHomeDirectory() + "/Applications/Ghostty.app/Contents/Resources/ghostty/themes",
            NSHomeDirectory() + "/.config/ghostty/themes",
        ]
        var result: [ThemePreview] = []
        for dir in paths {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for file in files.sorted() {
                let path = (dir as NSString).appendingPathComponent(file)
                guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let bg = parseColor(from: content, key: "background") ?? NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
                let fg = parseColor(from: content, key: "foreground") ?? .white
                let palette = parsePalette(from: content)
                result.append(ThemePreview(id: file, background: bg, foreground: fg, palette: palette))
            }
        }
        var seen = Set<String>()
        themes = result.filter { seen.insert($0.id).inserted }
    }

    private func parseColor(from content: String, key: String) -> NSColor? {
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix(key),
                  t.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("="),
                  let eq = t.firstIndex(of: "=")
            else { continue }
            let hex = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
            guard hex.count == 6, let val = UInt64(hex, radix: 16) else { continue }
            return NSColor(
                srgbRed: CGFloat((val >> 16) & 0xFF) / 255,
                green: CGFloat((val >> 8) & 0xFF) / 255,
                blue: CGFloat(val & 0xFF) / 255,
                alpha: 1
            )
        }
        return nil
    }

    private func parsePalette(from content: String) -> [NSColor] {
        let pattern = #"([0-9]{1,2})\s*=\s*#([0-9a-fA-F]{6})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))

        var indexed: [Int: NSColor] = [:]
        for match in matches {
            guard match.numberOfRanges == 3 else { continue }
            let iString = ns.substring(with: match.range(at: 1))
            let hex = ns.substring(with: match.range(at: 2))
            guard let idx = Int(iString), let val = UInt64(hex, radix: 16) else { continue }
            indexed[idx] = NSColor(
                srgbRed: CGFloat((val >> 16) & 0xFF) / 255,
                green: CGFloat((val >> 8) & 0xFF) / 255,
                blue: CGFloat(val & 0xFF) / 255,
                alpha: 1
            )
        }

        return indexed.keys.sorted().compactMap { indexed[$0] }
    }

    private func colorChip(_ color: NSColor) -> some View {
        Rectangle()
            .fill(Color(nsColor: color))
            .frame(width: 16, height: 16)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.quaternary))
    }
}

// MARK: - Quick Terminal

private struct QuickTerminalSettings: View {
    @AppStorage("macterm.quickTerminal.enabled")
    private var enabled = true
    @State
    private var qtWidth: Double = 0.6
    @State
    private var qtHeight: Double = 0.5

    var body: some View {
        Form {
            Section("Quick Terminal") {
                Toggle("Enable Quick Terminal", isOn: $enabled)

                HStack {
                    Text("Width")
                    Slider(value: $qtWidth, in: 0.2 ... 1.0, step: 0.05)
                    Text("\(Int(qtWidth * 100))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                .onChange(of: qtWidth) { _, v in
                    UserDefaults.standard.set(v, forKey: "macterm.quickTerminal.width")
                }
                .disabled(!enabled)

                HStack {
                    Text("Height")
                    Slider(value: $qtHeight, in: 0.2 ... 1.0, step: 0.05)
                    Text("\(Int(qtHeight * 100))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                .onChange(of: qtHeight) { _, v in
                    UserDefaults.standard.set(v, forKey: "macterm.quickTerminal.height")
                }
                .disabled(!enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            let w = UserDefaults.standard.double(forKey: "macterm.quickTerminal.width")
            let h = UserDefaults.standard.double(forKey: "macterm.quickTerminal.height")
            qtWidth = w > 0 ? w : 0.6
            qtHeight = h > 0 ? h : 0.5
        }
    }
}

// MARK: - Keymaps

private struct KeymapSettings: View {
    @State
    private var values: [String: String] = [:]
    @State
    private var capturingActionID: String?
    @State
    private var invalidActions: Set<String> = []

    var body: some View {
        Form {
            Section("Keyboard Shortcuts") {
                ForEach(HotkeyAction.allCases) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        Button {
                            HotkeyCaptureState.shared.isCapturing = true
                            capturingActionID = action.id
                        } label: {
                            Text(capturingActionID == action.id ? "Press keys..." : HotkeyRegistry
                                .displayString(for: values[action.id] ?? "disabled"))
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 140, alignment: .leading)
                        }
                        .buttonStyle(.bordered)

                        Button("Clear") {
                            values[action.id] = "disabled"
                            HotkeyRegistry.setShortcutString("disabled", for: action)
                            invalidActions.remove(action.id)
                            if capturingActionID == action.id {
                                capturingActionID = nil
                                HotkeyCaptureState.shared.isCapturing = false
                            }
                        }
                        .buttonStyle(.borderless)

                        if invalidActions.contains(action.id) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .background(
            HotkeyCaptureView(capturingActionID: $capturingActionID) { event, actionID in
                guard let action = HotkeyAction(rawValue: actionID),
                      let shortcut = HotkeyRegistry.shortcutString(from: event)
                else { return }
                values[action.id] = shortcut
                HotkeyRegistry.setShortcutString(shortcut, for: action)
                invalidActions.remove(action.id)
                capturingActionID = nil
                HotkeyCaptureState.shared.isCapturing = false
            }
        )
        .onAppear {
            var map: [String: String] = [:]
            for action in HotkeyAction.allCases {
                map[action.id] = HotkeyRegistry.selectedShortcutString(for: action)
            }
            values = map
        }
        .onDisappear {
            capturingActionID = nil
            HotkeyCaptureState.shared.isCapturing = false
        }
    }

    private func commit(_ action: HotkeyAction) {
        let input = (values[action.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard HotkeyRegistry.isValidShortcutString(input) else {
            invalidActions.insert(action.id)
            return
        }
        invalidActions.remove(action.id)
        HotkeyRegistry.setShortcutString(input, for: action)
    }
}

private struct HotkeyCaptureView: NSViewRepresentable {
    @Binding
    var capturingActionID: String?
    let onCapture: (NSEvent, String) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.view
    }

    func updateNSView(_: NSView, context: Context) {
        context.coordinator.capturingActionID = capturingActionID
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    @MainActor
    final class Coordinator: NSObject {
        let view: NSView
        var capturingActionID: String?
        private var monitor: Any?
        private let onCapture: (NSEvent, String) -> Void

        init(onCapture: @escaping (NSEvent, String) -> Void) {
            self.onCapture = onCapture
            view = NSView()
            super.init()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let actionID = self.capturingActionID else { return event }
                if event.keyCode == 53 {
                    self.capturingActionID = nil
                    HotkeyCaptureState.shared.isCapturing = false
                    return nil
                }
                self.onCapture(event, actionID)
                return nil
            }
        }
    }
}

// MARK: - Font picker

private struct MonoFontPicker: NSViewRepresentable {
    let fonts: [String]
    @Binding var selection: String

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.selectionChanged(_:))
        button.font = .systemFont(ofSize: 12)
        rebuild(button)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        if button.numberOfItems != fonts.count + 1 {
            rebuild(button)
        }
        let title = selection.isEmpty ? "Default" : selection
        if button.titleOfSelectedItem != title {
            button.selectItem(withTitle: title)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    private func rebuild(_ button: NSPopUpButton) {
        button.removeAllItems()
        let menu = NSMenu()

        let defaultItem = NSMenuItem(title: "Default", action: nil, keyEquivalent: "")
        defaultItem.representedObject = ""
        menu.addItem(defaultItem)
        menu.addItem(.separator())

        for family in fonts {
            let item = NSMenuItem(title: family, action: nil, keyEquivalent: "")
            item.representedObject = family
            if let font = NSFont(name: family, size: 13) {
                item.attributedTitle = NSAttributedString(
                    string: family,
                    attributes: [.font: font]
                )
            }
            menu.addItem(item)
        }

        button.menu = menu
        let title = selection.isEmpty ? "Default" : selection
        button.selectItem(withTitle: title)
    }

    final class Coordinator: NSObject {
        let parent: MonoFontPicker

        init(_ parent: MonoFontPicker) {
            self.parent = parent
        }

        @objc
        func selectionChanged(_ sender: NSPopUpButton) {
            let value = sender.selectedItem?.representedObject as? String ?? ""
            if parent.selection != value {
                parent.selection = value
            }
        }
    }
}

// MARK: - Config

private struct ConfigSettings: View {
    var body: some View {
        Form {
            Section("Configuration File") {
                Text("Terminal settings (font, scrollbar, opacity, blur, etc.) are configured via ghostty.conf.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Open Config File") {
                        NSWorkspace.shared.open(MactermConfig.shared.ghosttyConfigURL)
                    }
                    Button("Reload Config") {
                        GhosttyApp.shared.reloadConfig()
                    }
                }

                Text(MactermConfig.shared.ghosttyConfigURL.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}
