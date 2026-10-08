import SwiftUI

/// Settings → Palettes: every screen the command palette can open, each
/// with a switch. Off, a screen leaves the palette's list and its menu, and
/// its chord says where it went; the chord itself stays bound in Settings →
/// Keymaps for when it comes back. The built-in screens are Swift
/// (`Palette/Scopes/`); the custom ones are the files in
/// `~/.config/macterm/palettes/` (`CustomPaletteStore`), a file that failed
/// to read shown with its error in place of a switch.
struct PalettesSettings: View {
    @Environment(AppState.self)
    private var appState

    var body: some View {
        Form {
            Section {
                ForEach(PaletteScopeID.builtIn, id: \.self) { scope in
                    PaletteRow(
                        title: scope.pill.title,
                        summary: scope.summary,
                        icon: scope.pill.systemImage,
                        settingsID: scope.settingsID
                    )
                }
            } header: {
                DocsSectionHeader("Built-in Palettes", docs: .palettes)
            }

            Section {
                if appState.customPalettes.entries.isEmpty {
                    Text("No custom palettes.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.customPalettes.entries) { entry in
                        PaletteRow(
                            title: entry.pill.title,
                            summary: entry.failure?.localizedDescription ?? entry.description ?? entry.fileURL.lastPathComponent,
                            icon: entry.pill.systemImage,
                            settingsID: entry.settingsID,
                            warning: entry.failure.map { "\(entry.fileURL.lastPathComponent): \($0.localizedDescription)" }
                        )
                    }
                }
                LabeledContent("Palettes folder") {
                    Button(Self.folderPath(appState)) {
                        appState.customPalettes.revealDirectory()
                    }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            } header: {
                DocsSectionHeader("Custom Palettes", docs: .customPalettes)
            } footer: {
                Text(
                    "A palette is a YAML file in the folder: a command whose output becomes rows, "
                        + "each opening another screen or running a command. "
                        + "A palette turned off leaves the command palette and its menu; "
                        + "its keybind, if any, says so instead of reaching the terminal."
                )
                .settingsCaption()
            }
        }
        .formStyle(.grouped)
        .onAppear { appState.customPalettes.reloadIfChanged() }
    }

    /// `~/.config/macterm/palettes`, home-contracted.
    static func folderPath(_ appState: AppState) -> String {
        let path = appState.customPalettes.directoryURL.path(percentEncoded: false)
        let home = ProjectPath.currentHome
        let shown = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        return shown.hasSuffix("/") ? String(shown.dropLast()) : shown
    }
}

private struct PaletteRow: View {
    let title: String
    let summary: String
    let icon: String
    let settingsID: String
    /// Why the palette's file didn't read, shown as a warning glyph beside
    /// the switch; the switch still works, so a broken palette can be
    /// turned off while it is fixed.
    let warning: String?

    @State private var enabled: Bool

    init(title: String, summary: String, icon: String, settingsID: String, warning: String? = nil) {
        self.title = title
        self.summary = summary
        self.icon = icon
        self.settingsID = settingsID
        self.warning = warning
        _enabled = State(initialValue: Preferences.shared.isPaletteEnabled(settingsID))
    }

    var body: some View {
        Toggle(isOn: $enabled) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if !summary.isEmpty {
                        Text(summary)
                            .settingsCaption()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let warning {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MactermTheme.failure)
                        .help(warning)
                }
            }
        }
        .onChange(of: enabled) { _, on in
            Preferences.shared.setPalette(settingsID, enabled: on)
        }
    }
}
