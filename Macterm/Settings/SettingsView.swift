import AppKit
import Carbon
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            QuickTerminalSettings()
                .tabItem {
                    Label("Quick Terminal", systemImage: "rectangle.bottomthird.inset.filled")
                }
            KeymapSettings()
                .tabItem { Label("Keymaps", systemImage: "keyboard") }
            UpdatesSettings()
                .tabItem { Label("Updates", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(width: 520, height: 540)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(Preferences.Keys.autoTiling)
    private var autoTilingEnabled = false
    @State
    private var ghosttyConfigPath: String = Preferences.shared.userGhosttyConfigPath

    var body: some View {
        Form {
            Section("Ghostty Config") {
                HStack {
                    TextField(
                        "Path", text: $ghosttyConfigPath, prompt: Text("~/.config/ghostty/config")
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitPath() }
                    Button("Browse…") { browse() }
                    Button("Reload") {
                        commitPath()
                        GhosttyApp.shared.reloadAndReport()
                    }
                    .help("Re-read your Ghostty config. Click after saving external edits.")
                }
                Text(
                    "Your Ghostty config controls theme, font, palette, keybinds, and most other terminal settings. "
                        + "Macterm provides defaults; anything in your Ghostty config overrides them. "
                        + "Macterm does not auto-detect external edits — click Reload after saving."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Section("Layout") {
                Toggle("Auto-tile panes", isOn: $autoTilingEnabled)
                    .onChange(of: autoTilingEnabled) { _, v in
                        Preferences.shared.autoTilingEnabled = v
                    }
                Text("Distributes pane sizes evenly on split and close.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Push the text-field's current value into Preferences and reload. We
    /// don't bind directly because that would reload on every keystroke;
    /// debouncing on submit/blur matches how the path is typically edited.
    /// If the new path produces errors, the alert surfaces via `reloadAndReport`.
    private func commitPath() {
        guard ghosttyConfigPath != Preferences.shared.userGhosttyConfigPath else { return }
        Preferences.shared.userGhosttyConfigPath = ghosttyConfigPath
        GhosttyApp.shared.reloadAndReport()
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        // Default the panel to the user's currently configured path's
        // directory so they don't always start from ~.
        let current = Preferences.shared.expandedUserGhosttyConfigPath
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ghosttyConfigPath = url.path(percentEncoded: false)
        commitPath()
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(Preferences.Keys.projectIconSymbol)
    private var projectIconSymbol = "folder"
    @AppStorage(Preferences.Keys.tabIconSymbol)
    private var tabIconSymbol = "terminal"
    @AppStorage(Preferences.Keys.showNewProjectButton)
    private var showNewProjectButton = true
    @AppStorage(Preferences.Keys.tabSwitcherVisibility)
    private var tabSwitcherVisibility = TabSwitcherVisibility.whenMultiple.rawValue
    @State
    private var backgroundOpacity: Double = Preferences.shared.windowOpacity
    @State
    private var backgroundBlurRadius: Double = .init(Preferences.shared.windowBlurRadius)

    var body: some View {
        Form {
            Section("Window") {
                HStack {
                    Text("Background Opacity")
                    Slider(value: $backgroundOpacity, in: 0.3 ... 1.0)
                    Text("\(Int((backgroundOpacity * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                .onChange(of: backgroundOpacity) { _, v in
                    Preferences.shared.windowOpacity = v
                }

                HStack {
                    Text("Background Blur")
                    Slider(value: $backgroundBlurRadius, in: 0 ... 100)
                    Text("\(Int(backgroundBlurRadius.rounded()))")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                .onChange(of: backgroundBlurRadius) { _, v in
                    Preferences.shared.windowBlurRadius = Int(v.rounded())
                }
                .disabled(backgroundOpacity >= 0.999)

                Text("Blur only takes effect when opacity is below 100%. Set to 0 to disable.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Sidebar") {
                Picker("Project icon", selection: $projectIconSymbol) {
                    ForEach(Preferences.projectIconChoices, id: \.self) { name in
                        iconPickerLabel(name).tag(name)
                    }
                }
                .onChange(of: projectIconSymbol) { _, v in Preferences.shared.projectIconSymbol = v }

                Picker("Tab icon", selection: $tabIconSymbol) {
                    ForEach(Preferences.tabIconChoices, id: \.self) { name in
                        iconPickerLabel(name).tag(name)
                    }
                }
                .onChange(of: tabIconSymbol) { _, v in Preferences.shared.tabIconSymbol = v }

                Toggle("Show New Project button", isOn: $showNewProjectButton)
                    .onChange(of: showNewProjectButton) { _, v in Preferences.shared.showNewProjectButton = v }
                Text("When hidden, create projects via the command palette or context menu.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Toolbar") {
                Picker("Tab switcher", selection: $tabSwitcherVisibility) {
                    ForEach(TabSwitcherVisibility.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .onChange(of: tabSwitcherVisibility) { _, v in
                    Preferences.shared.tabSwitcherVisibility = TabSwitcherVisibility(rawValue: v) ?? .whenMultiple
                }
                Text("Numbered control in the title bar for switching tabs by index.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func iconPickerLabel(_ name: String) -> some View {
        switch name {
        case Preferences.noIcon:
            Text("None")
        case Preferences.numberIconCircleFill:
            Label("Number — filled circle", systemImage: "1.circle.fill")
        case Preferences.numberIconCircle:
            Label("Number — circle", systemImage: "1.circle")
        case Preferences.numberIconSquareFill:
            Label("Number — filled square", systemImage: "1.square.fill")
        case Preferences.numberIconSquare:
            Label("Number — square", systemImage: "1.square")
        case Preferences.numberIconPlain:
            Text("Number")
        default:
            Label(name, systemImage: name)
        }
    }
}

// MARK: - Quick Terminal

private struct QuickTerminalSettings: View {
    @AppStorage(Preferences.Keys.quickTerminalEnabled)
    private var enabled = true
    @State
    private var qtWidth: Double = Preferences.shared.quickTerminalWidthFraction
    @State
    private var qtHeight: Double = Preferences.shared.quickTerminalHeightFraction

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
                    Preferences.shared.quickTerminalWidthFraction = v
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
                    Preferences.shared.quickTerminalHeightFraction = v
                }
                .disabled(!enabled)

                LabeledContent(
                    "Shortcut",
                    value: HotkeyRegistry.displayString(
                        for: HotkeyRegistry.selectedShortcutString(for: .toggleQuickTerminal)
                    )
                )
                Text("Rebind in Settings → Keymaps. Works globally, even when Macterm isn't the active app.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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
                            Text(
                                capturingActionID == action.id
                                    ? "Press keys..."
                                    : HotkeyRegistry
                                    .displayString(for: values[action.id] ?? "disabled")
                            )
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

// MARK: - Updates

private struct UpdatesSettings: View {
    @ObservedObject
    private var updater: Updater = .shared
    @State
    private var automaticallyChecks: Bool = Updater.shared.automaticallyChecksForUpdates
    @State
    private var automaticallyDownloads: Bool = Updater.shared.automaticallyDownloadsUpdates

    var body: some View {
        Form {
            Section("Automatic Updates") {
                Toggle("Check for updates automatically", isOn: $automaticallyChecks)
                    .onChange(of: automaticallyChecks) { _, v in
                        updater.automaticallyChecksForUpdates = v
                    }

                Toggle("Download updates in the background", isOn: $automaticallyDownloads)
                    .disabled(!automaticallyChecks)
                    .onChange(of: automaticallyDownloads) { _, v in
                        updater.automaticallyDownloadsUpdates = v
                    }

                HStack {
                    Spacer()
                    Button("Check for Updates Now") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                }

                Text(
                    "Updates are verified with an EdDSA signature. Macterm does not collect analytics."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Version") {
                LabeledContent("Current version", value: Self.bundleVersionString)
            }
        }
        .formStyle(.grouped)
    }

    private static var bundleVersionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let commit = Bundle.main.infoDictionary?["GitCommit"] as? String ?? ""
        // Hide the placeholder — it only survives into dev builds that don't
        // go through scripts/build.sh (swift run, Xcode previews, etc.).
        let looksReal = !commit.isEmpty && commit != "GIT_COMMIT_PLACEHOLDER"
        return looksReal ? "\(short) (\(commit))" : short
    }
}
