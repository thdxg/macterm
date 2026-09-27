import AppKit
import SwiftUI

/// Settings → Widgets: what a new desktop widget starts as, and every widget
/// on the desktop — each one editable, resizable and removable from here as
/// from its own right-click menu, since a widget can be hidden behind
/// windows or on a display that isn't in front of the user.
struct WidgetsSettings: View {
    @Environment(AppState.self)
    private var appState

    @State
    private var defaultSize: DesktopWidgetSize = Preferences.shared.desktopWidgetDefaultSize

    var body: some View {
        Form {
            Section("New Widgets") {
                Picker("Default size", selection: $defaultSize) {
                    ForEach(DesktopWidgetSize.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
                .onChange(of: defaultSize) { _, size in
                    Preferences.shared.desktopWidgetDefaultSize = size
                }
                Text("A new widget runs your login shell, opens locked at the center of the desktop, and snaps to the widget grid.")
                    .settingsCaption()
            }

            Section {
                if appState.desktopWidgets.isEmpty {
                    Text("No widgets.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(appState.desktopWidgets.enumerated()), id: \.element.id) { index, widget in
                        WidgetRow(index: index + 1, widget: widget)
                    }
                }
                Text(
                    "Widgets are locked: drag one anywhere to move it, but nothing you click or type reaches its terminal. "
                        + "Edit one to type into it or resize it from its edges. One widget can be edited at a time."
                )
                .settingsCaption()
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
                HStack {
                    Text("Widgets")
                    Spacer()
                    Button {
                        appState.createDesktopWidget()
                    } label: {
                        Label("New Widget", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Add a widget at the center of the desktop")
                }
            }
        }
        .formStyle(.grouped)
    }

    /// `~/.config/macterm/widgets/widgets.yaml`, home-contracted.
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

            if isEditing {
                Button("Done") { appState.endEditingDesktopWidget() }
            } else {
                Button("Edit") { appState.beginEditingDesktopWidget(id: widget.id) }
                    .disabled(!appState.canEditDesktopWidget(id: widget.id))
                    .help(appState.canEditDesktopWidget(id: widget.id) ? "" : "Finish editing the other widget first")
            }

            Menu {
                Picker("Size", selection: Binding(
                    get: { DesktopWidgetSize(span: widget.span) },
                    set: { size in
                        if let size { appState.setDesktopWidgetSpan(size.span, id: widget.id) }
                    }
                )) {
                    ForEach(DesktopWidgetSize.allCases, id: \.self) { size in
                        Text(size.title).tag(DesktopWidgetSize?.some(size))
                    }
                }
                Divider()
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
        switch DesktopWidgetSize(span: widget.span) {
        case .small: "widget.small"
        case .medium: "widget.medium"
        default: "widget.large"
        }
    }

    /// Size, then what it runs: its command, else its session — the name
    /// `pane dump --session` takes.
    private var subtitle: String {
        let size = DesktopWidgetSize.title(of: widget.span)
        let runs = widget.command ?? widget.pane?.sessionName ?? ""
        return runs.isEmpty ? size : "\(size) · \(runs)"
    }
}
