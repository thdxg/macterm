import AppKit
import SwiftUI

/// Settings → Widgets: every widget on the desktop, each removable from here,
/// since a widget can be hidden behind windows or on a display that isn't in
/// front of the user. Editing — typing into it, moving and resizing it — is
/// not offered here: it starts from the widget itself (right-click → Edit
/// Widget).
struct WidgetsSettings: View {
    @Environment(AppState.self)
    private var appState

    var body: some View {
        Form {
            Section {
                if appState.desktopWidgets.isEmpty {
                    Text("No widgets.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(appState.desktopWidgets.enumerated()), id: \.element.id) { index, widget in
                        WidgetRow(index: index + 1, widget: widget)
                    }
                }
                LabeledContent("Layout file") {
                    Button(WidgetsSettings.layoutFilePath(appState)) {
                        NSWorkspace.shared.activateFileViewerSelecting([appState.widgetLayoutStore.fileURL])
                    }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .disabled(!FileManager.default.fileExists(atPath: appState.widgetLayoutStore.fileURL.path))
                }
            } header: {
                DocsSectionHeader("Widgets", docs: .desktopWidgets) {
                    Button {
                        appState.createDesktopWidget()
                    } label: {
                        Label("New Widget", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Add a widget at the center of the desktop")
                }
            } footer: {
                Text("A widget is a terminal on your desktop. Edit one to move or resize it.")
                    .settingsCaption()
            }
        }
        .formStyle(.grouped)
    }

    /// `~/.config/macterm/widgets.yaml`, home-contracted.
    static func layoutFilePath(_ appState: AppState) -> String {
        let path = appState.widgetLayoutStore.fileURL.path(percentEncoded: false)
        let home = ProjectPath.currentHome
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private struct WidgetRow: View {
    let index: Int
    let widget: DesktopWidget

    @Environment(AppState.self)
    private var appState

    private var isEditing: Bool { appState.editingDesktopWidgetID == widget.id }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(isEditing ? AnyShapeStyle(MactermTheme.accent) : AnyShapeStyle(.secondary))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(widget.name ?? "Widget \(index)")
                Text(subtitle)
                    .settingsCaption()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            // Editing starts from the widget itself (right-click → Edit
            // Widget), where the user is looking; the accent icon marks the
            // one being edited.
            Menu {
                Button("Remove", role: .destructive) {
                    DesktopWidgetRemoval.confirmAndRemove(widget.id, in: appState)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        let span = widget.span
        if span.columns == 1, span.rows == 1 { return "widget.small" }
        return span.columns > span.rows ? "widget.medium" : "widget.large"
    }

    /// Size, then what it runs: its command, else its session — the name
    /// `pane dump --session` takes.
    private var subtitle: String {
        let size = "\(widget.span.columns) × \(widget.span.rows)"
        let runs = widget.command ?? widget.pane?.sessionName ?? ""
        return runs.isEmpty ? size : "\(size) · \(runs)"
    }
}
