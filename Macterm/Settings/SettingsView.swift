import AppKit
import Carbon
import SwiftUI

/// The panes of the settings window, in sidebar order. Titles are the
/// user-visible sidebar labels — Title Case, matching the macOS convention the
/// rest of the app's menus follow.
private enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case projects = "Projects"
    case appearance = "Appearance"
    case quickTerminal = "Quick Terminal"
    case keymaps = "Keymaps"
    case updates = "Updates"

    var id: String { rawValue }
    var title: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .projects: "folder"
        case .appearance: "paintpalette"
        case .quickTerminal: "rectangle.bottomthird.inset.filled"
        case .keymaps: "keyboard"
        case .updates: "arrow.triangle.2.circlepath"
        }
    }
}

/// Sidebar-style preferences window, mirroring the macOS System Settings
/// shape: a source list of panes on the left, the selected pane's `Form` on the
/// right. `NavigationSplitView` is the native container for that — no custom
/// list/selection plumbing.
struct SettingsView: View {
    @State private var selection: SettingsPane = .general

    /// Sidebar width. A single value for min/ideal/max pins the column: the
    /// divider stops being draggable, because there's no range to drag within.
    private static let sidebarWidth: CGFloat = 190

    /// Floor for the content column — enough for the widest pane's controls
    /// (the Keymaps rows) without horizontal clipping.
    private static let detailMinWidth: CGFloat = 520

    var body: some View {
        // Pinning `columnVisibility` drops the collapse toolbar button — System
        // Settings has no such control, and there's nothing to reveal when the
        // pane list is the only way to navigate. It does NOT by itself stop
        // AppKit from auto-collapsing the sidebar when the window gets narrow;
        // the window's own `minWidth` (sidebar + detail floor) is what
        // guarantees both columns always fit.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(SettingsPane.allCases, selection: $selection) { pane in
                NavigationLink(value: pane) {
                    Label(pane.title, systemImage: pane.symbol)
                }
            }
            .navigationSplitViewColumnWidth(Self.sidebarWidth)
            .hidingSidebarToggle()
        } detail: {
            detail
                .navigationTitle(selection.title)
                // The detail column drives the window width; without a floor it
                // collapses to the widest intrinsic row when a pane's content
                // is narrow (Updates), snapping the window on every switch.
                .frame(minWidth: Self.detailMinWidth)
        }
        // Extra window width goes to the content, not the fixed pane list.
        .navigationSplitViewStyle(.prominentDetail)
        .frame(
            minWidth: Self.sidebarWidth + Self.detailMinWidth,
            minHeight: 560
        )
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: GeneralSettings()
        case .projects: ProjectsSettings()
        case .appearance: AppearanceSettings()
        case .quickTerminal: QuickTerminalSettings()
        case .keymaps: KeymapSettings()
        case .updates: UpdatesSettings()
        }
    }
}

// MARK: - Shared styling

extension View {
    /// The one style for a control's explanatory line. Every pane's
    /// descriptions went through this by hand before (one had drifted to
    /// `.footnote`), so it lives in a modifier now.
    func settingsCaption() -> some View {
        font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    /// Drops the sidebar collapse button. The API landed in macOS 15; on 14 the
    /// pinned `columnVisibility` already makes the button inert, so the older
    /// system just keeps a harmless no-op control rather than a broken one.
    @ViewBuilder
    func hidingSidebarToggle() -> some View {
        if #available(macOS 15.0, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    // Seeded from and written back through `Preferences` (the single
    // UserDefaults seam that redirects to a wiped side-suite under XCTest).
    // NOT `@AppStorage`, which binds to `UserDefaults.standard` — banned by the
    // project, and it diverged from the `.onChange` write-through under test.
    @State private var autoTilingEnabled: Bool = Preferences.shared.autoTilingEnabled
    @State private var eagerlyStartProjectTabs: Bool = Preferences.shared.eagerlyStartProjectTabs
    @State private var terminateSessionsOnQuit: Bool = Preferences.shared.terminateSessionsOnQuit

    /// Why session persistence is inactive, when it is. Missing binary is a
    /// dev-build state; an over-budget socket path is an environment problem
    /// (very long home/TMPDIR paths push past sun_path).
    private var zmxUnavailableReason: String {
        if !ZmxClient.live.isBundled() {
            return "Session persistence is inactive: the zmx binary isn't bundled. Run `mise run setup` and rebuild."
        }
        return "Session persistence is inactive: this system's zmx socket path is too long. Terminals run without persistence."
    }

    @State
    private var terminalScrollSpeed: Double = Preferences.shared.terminalScrollSpeed
    @State
    private var ghosttyConfigPath: String = Preferences.shared.userGhosttyConfigPath

    var body: some View {
        Form {
            // Read the CLI probe from the process-lifetime cache — never spawn
            // `ghostty +help` from inside `body` (it re-ran on every @State
            // change, e.g. each scroll-speed slider tick, blocking the main
            // thread on `waitUntilExit`; #3.1).
            if !GhosttyCLIProbe.isInstalled {
                GhosttyCLIBanner(reason: .notInstalled)
            } else if GhosttyCLIProbe.sshWrapperBinDir == nil {
                GhosttyCLIBanner(reason: .tooOldForSSH)
            }

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
                Text("Controls theme, font, palette, and keybinds. Click Reload after editing it elsewhere.")
                    .settingsCaption()
            }

            Section("Terminal") {
                HStack {
                    Text("Scroll speed")
                    Slider(value: $terminalScrollSpeed, in: 0.25 ... 3.0)
                    Text("\(terminalScrollSpeed, specifier: "%.2f")×")
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                }
                .onChange(of: terminalScrollSpeed) { _, v in
                    Preferences.shared.terminalScrollSpeed = v
                }
                Text("Scrollback speed for trackpads and mouse wheels.")
                    .settingsCaption()
            }

            Section("Layout") {
                Toggle("Auto-tile panes", isOn: $autoTilingEnabled)
                    .onChange(of: autoTilingEnabled) { _, v in
                        Preferences.shared.autoTilingEnabled = v
                    }
                Text("Distributes pane sizes evenly on split and close.")
                    .settingsCaption()

                Toggle("Start all tabs of the focused project", isOn: $eagerlyStartProjectTabs)
                    .onChange(of: eagerlyStartProjectTabs) { _, v in
                        Preferences.shared.eagerlyStartProjectTabs = v
                    }
                Text("Runs every tab's processes when a project opens, not just the active tab.")
                    .settingsCaption()
            }

            Section("Session Persistence") {
                Toggle("Quit terminals when Macterm quits", isOn: $terminateSessionsOnQuit)
                    .onChange(of: terminateSessionsOnQuit) { _, v in
                        Preferences.shared.terminateSessionsOnQuit = v
                    }
                Text("Off: shells keep running after you quit and reattach on next launch.")
                    .settingsCaption()

                // Persistence can be silently unavailable (Supacode shipped the
                // same probe and users only noticed via a buried log line) —
                // say so where the toggle lives.
                if ZmxClient.live.executableURL() == nil {
                    Label {
                        Text(zmxUnavailableReason)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(MactermTheme.warning)
                }
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

// MARK: - Missing CLI banner

/// Shown in General settings when the standalone ghostty CLI (shipped in
/// Ghostty.app) is missing or too old to drive the shell-integration wrappers.
/// A few wrappers exec that binary (the `ssh` wrapper calls `ghostty +ssh`), so
/// without a compatible CLI those features are disabled and fall through to the
/// plain command — the README link spells out which. Embedded directly in a
/// `Form`, so it renders as its own section.
private struct GhosttyCLIBanner: View {
    enum Reason {
        case notInstalled
        case tooOldForSSH

        var message: String {
            switch self {
            case .notInstalled:
                "Ghostty.app isn't installed, so a few shell-integration features can't run."
            case .tooOldForSSH:
                "Your installed Ghostty.app is too old for the ssh shell integration. "
                    + "Update Ghostty.app to forward terminfo over ssh; until then, ssh runs normally."
            }
        }
    }

    let reason: Reason

    private static let detailsURL = URL(
        string: "https://github.com/thdxg/macterm#shell-integration"
    )

    var body: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Some features are disabled")
                        .font(.system(size: 13, weight: .semibold))
                    Text(reason.message)
                        .settingsCaption()
                    if let url = Self.detailsURL {
                        Link("Learn more", destination: url)
                            .font(.system(size: 11))
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MactermTheme.warning)
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    private let sliderLabelWidth: CGFloat = 126

    // Seeded from / written back through `Preferences` (see GeneralSettings) —
    // not `@AppStorage`, which would bind to the banned `UserDefaults.standard`.
    @State private var projectIconSymbol: String = Preferences.shared.projectIconSymbol
    @State private var tabIconSymbol: String = Preferences.shared.tabIconSymbol
    @State private var showAgentIcons: Bool = Preferences.shared.showAgentIcons
    @State private var showTabStatusIndicator: Bool = Preferences.shared.showTabStatusIndicator
    @State private var showNewProjectButton: Bool = Preferences.shared.showNewProjectButton
    @State private var tabSwitcherVisibility: String = Preferences.shared.tabSwitcherVisibility.rawValue
    @State private var tabSwitcherPosition: String = Preferences.shared.tabSwitcherPosition.rawValue
    @State
    private var backgroundOpacity: Double = Preferences.shared.windowOpacity
    @State
    private var backgroundBlurRadius: Double = .init(Preferences.shared.windowBlurRadius)
    @State
    private var liquidGlass: Bool = Preferences.shared.windowGlassEnabled
    @State
    private var liquidGlassStyle: WindowGlassStyle = Preferences.shared.windowGlassStyle
    @State
    private var paneDimOpacity: Double = Preferences.shared.paneDimOpacity

    var body: some View {
        Form {
            Section("Window") {
                HStack {
                    Text("Background opacity")
                        .frame(width: sliderLabelWidth, alignment: .leading)
                    Slider(value: $backgroundOpacity, in: 0.0 ... 1.0)
                    Text("\(Int((backgroundOpacity * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                .onChange(of: backgroundOpacity) { _, v in
                    Preferences.shared.windowOpacity = v
                }

                // Liquid glass (NSGlassEffectView) exists only on macOS 26+;
                // hide the control entirely on older systems where it'd be
                // inert rather than show a dead picker. "None" off / a style on
                // are folded into one picker over the two underlying prefs.
                if WindowAppearance.glassSupported {
                    Picker("Liquid Glass", selection: glassSelection) {
                        Text("None").tag(WindowGlassStyle?.none)
                        ForEach(WindowGlassStyle.allCases) { style in
                            Text(style.displayName).tag(WindowGlassStyle?.some(style))
                        }
                    }
                    .disabled(backgroundOpacity >= 0.999)
                }

                HStack {
                    Text("Background blur")
                        .frame(width: sliderLabelWidth, alignment: .leading)
                    Slider(value: $backgroundBlurRadius, in: 0 ... 100)
                    Text("\(Int(backgroundBlurRadius.rounded()))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                .onChange(of: backgroundBlurRadius) { _, v in
                    Preferences.shared.windowBlurRadius = Int(v.rounded())
                }
                .disabled(backgroundOpacity >= 0.999 || liquidGlass)

                Text(blurFootnote)
                    .settingsCaption()
            }

            Section("Split Panes") {
                HStack {
                    Text("Unfocused dimming")
                        .frame(width: sliderLabelWidth, alignment: .leading)
                    Slider(value: $paneDimOpacity, in: 0.0 ... Preferences.maxPaneDimOpacity)
                    Text("\(Int((paneDimOpacity / Preferences.maxPaneDimOpacity * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                .onChange(of: paneDimOpacity) { _, v in
                    Preferences.shared.paneDimOpacity = v
                }
                Text("How dark unfocused panes get in a split layout.")
                    .settingsCaption()
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

                Toggle("Show AI agent icons", isOn: $showAgentIcons)
                    .onChange(of: showAgentIcons) { _, v in
                        Preferences.shared.showAgentIcons = v
                    }
                Text("Uses the logo of the AI agent running in a tab as its icon.")
                    .settingsCaption()

                Toggle("Show tab status indicator", isOn: $showTabStatusIndicator)
                    .onChange(of: showTabStatusIndicator) { _, v in
                        Preferences.shared.showTabStatusIndicator = v
                    }
                Text("Shows a spinner while a command runs, and a dot when it finishes.")
                    .settingsCaption()

                Toggle("Show New Project button", isOn: $showNewProjectButton)
                    .onChange(of: showNewProjectButton) { _, v in Preferences.shared.showNewProjectButton = v }
                Text("When hidden, create projects via the command palette or context menu.")
                    .settingsCaption()
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
                    .settingsCaption()

                Picker("Tab switcher position", selection: $tabSwitcherPosition) {
                    ForEach(TabSwitcherPosition.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .onChange(of: tabSwitcherPosition) { _, v in
                    Preferences.shared.tabSwitcherPosition = TabSwitcherPosition(rawValue: v) ?? .trailing
                }
                Text("Left places the switcher before the window title, next to the sidebar.")
                    .settingsCaption()
            }
        }
        .formStyle(.grouped)
    }

    /// One picker over the two glass prefs: `nil` ("None") means disabled, a
    /// concrete style means enabled with that material. The remembered style is
    /// preserved across a None round-trip — picking None only flips the enabled
    /// flag, so re-selecting glass restores the last material.
    private var glassSelection: Binding<WindowGlassStyle?> {
        Binding(
            get: { liquidGlass ? liquidGlassStyle : nil },
            set: { selection in
                if let selection {
                    liquidGlassStyle = selection
                    Preferences.shared.windowGlassStyle = selection
                    liquidGlass = true
                } else {
                    liquidGlass = false
                }
                Preferences.shared.windowGlassEnabled = liquidGlass
            }
        )
    }

    private var blurFootnote: String {
        if backgroundOpacity >= 0.999 {
            return WindowAppearance.glassSupported
                ? "Blur and Liquid Glass only take effect when opacity is below 100%."
                : "Blur only takes effect when opacity is below 100%."
        }
        if liquidGlass {
            return "Liquid Glass uses the macOS material (blur slider ignored). Regular is frostier; Clear is more transparent."
        }
        return "Set blur to 0 to disable."
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
            Label("Number", systemImage: "number")
        default:
            Label(name, systemImage: name)
        }
    }
}

// MARK: - Quick Terminal

private struct QuickTerminalSettings: View {
    private let sliderLabelWidth: CGFloat = 44

    /// Seeded from / written back through `Preferences` — not `@AppStorage`
    /// (banned `UserDefaults.standard`), and previously `enabled` wrote no
    /// Preferences value at all, so the observable stayed stale.
    @State private var enabled: Bool = Preferences.shared.quickTerminalEnabled
    @State
    private var qtWidth: Double = Preferences.shared.quickTerminalWidthFraction
    @State
    private var qtHeight: Double = Preferences.shared.quickTerminalHeightFraction

    var body: some View {
        Form {
            Section("Quick Terminal") {
                Toggle("Enable quick terminal", isOn: $enabled)
                    .onChange(of: enabled) { _, v in
                        Preferences.shared.quickTerminalEnabled = v
                    }

                HStack {
                    Text("Width")
                        .frame(width: sliderLabelWidth, alignment: .leading)
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
                        .frame(width: sliderLabelWidth, alignment: .leading)
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
                Text("Works globally, even when Macterm isn't active. Rebind it in Keymaps.")
                    .settingsCaption()
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

    /// Titles of the *other* actions that share `action`'s binding, for the
    /// inline conflict message.
    private func conflictPartners(for action: HotkeyAction) -> [String] {
        guard let key = HotkeyRegistry.conflictKey(for: values[action.id] ?? "disabled") else {
            return []
        }
        return HotkeyAction.allCases
            .filter { $0.id != action.id && HotkeyRegistry.conflictKey(for: values[$0.id] ?? "disabled") == key }
            .map(\.title)
    }

    /// Bindable actions grouped by the category of the `AppCommand` they back,
    /// so the keymaps list mirrors the command palette's sectioning instead of
    /// being one long flat list. Categories appear in `AppCommand.allCases`
    /// declaration order; actions keep their order within each.
    private var actionsByCategory: [(category: AppCommand.Category, actions: [HotkeyAction])] {
        var order: [AppCommand.Category] = []
        var grouped: [AppCommand.Category: [HotkeyAction]] = [:]
        for action in HotkeyAction.allCases {
            let category = action.appCommand.category
            if grouped[category] == nil { order.append(category) }
            grouped[category, default: []].append(action)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }

    var body: some View {
        Form {
            ForEach(actionsByCategory, id: \.category) { group in
                Section(group.category.rawValue) {
                    ForEach(group.actions) { action in
                        hotkeyRow(action)
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

    @ViewBuilder
    private func hotkeyRow(_ action: HotkeyAction) -> some View {
        let partners = conflictPartners(for: action)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(action.title)
                Spacer()
                Button {
                    HotkeyCaptureState.shared.isCapturing = true
                    capturingActionID = action.id
                } label: {
                    let isCapturing = capturingActionID == action.id
                    let isUnmapped = HotkeyRegistry
                        .displaySymbols(for: values[action.id] ?? "disabled").isEmpty
                    Text(
                        isCapturing
                            ? "Press keys..."
                            : HotkeyRegistry
                            .displayString(for: values[action.id] ?? "disabled")
                    )
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle((isUnmapped && !isCapturing) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .frame(width: 140, alignment: .leading)
                }
                .buttonStyle(.bordered)

                Button("Clear") {
                    values[action.id] = "disabled"
                    HotkeyRegistry.setShortcutString("disabled", for: action)
                    if capturingActionID == action.id {
                        capturingActionID = nil
                        HotkeyCaptureState.shared.isCapturing = false
                    }
                }
                .buttonStyle(.borderless)

                if !partners.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MactermTheme.warning)
                }
            }

            if !partners.isEmpty {
                Text("Conflicts with \(partners.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(MactermTheme.warning)
            }
        }
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

    /// Every `addLocalMonitorForEvents` needs a paired `removeMonitor`, or each
    /// visit to the Keymaps tab leaks a monitor (and one closure call per
    /// keyDown) for the process lifetime. Removal happens here — a `@MainActor`
    /// teardown hook — rather than in `deinit`, which is `nonisolated` under
    /// Swift 6 and can't touch the coordinator's non-Sendable `monitor`.
    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        coordinator.tearDown()
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
                if Int(event.keyCode) == kVK_Escape {
                    self.capturingActionID = nil
                    HotkeyCaptureState.shared.isCapturing = false
                    return nil
                }
                self.onCapture(event, actionID)
                return nil
            }
        }

        func tearDown() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

// MARK: - Updates

private struct UpdatesSettings: View {
    /// `Updater` is `@Observable`; read the singleton directly (Observation
    /// tracks `canCheckForUpdates`/`updateAvailable` reads in `body`).
    private var updater: Updater { .shared }
    @State
    private var automaticallyChecks: Bool = Updater.shared.automaticallyChecksForUpdates
    @State
    private var automaticallyDownloads: Bool = Updater.shared.automaticallyDownloadsUpdates
    @State
    private var updateChannel: String = Updater.shared.updateChannel.rawValue

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

                Text("Updates are verified with an EdDSA signature. No analytics are collected.")
                    .settingsCaption()
            }

            // Deliberately its own section, and NOT disabled when automatic
            // checks are off: the channel governs which updates are visible to
            // any check, including a manual "Check for Updates Now".
            Section("Channel") {
                Picker("Update channel", selection: $updateChannel) {
                    ForEach(UpdateChannel.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .onChange(of: updateChannel) { _, v in
                    updater.updateChannel = UpdateChannel(rawValue: v) ?? .stable
                }
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
