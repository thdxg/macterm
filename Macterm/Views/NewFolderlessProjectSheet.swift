import SwiftUI

/// Create a named group of tabs without a project folder.
struct NewFolderlessProjectSheet: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore
    @Environment(\.dismiss)
    private var dismiss
    @Environment(WindowState.self)
    private var windowState: WindowState?

    @State
    private var name = ""
    @FocusState
    private var nameIsFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Project Without Folder")
                .font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameIsFocused)
            Text("The first terminal starts in your home folder.")
                .settingsCaption()
            if PinnedTabs.reservesName(trimmedName) {
                Text(PinnedTabs.reservedNameMessage)
                    .settingsCaption()
                    .foregroundStyle(MactermTheme.warning)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || PinnedTabs.reservesName(trimmedName))
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { nameIsFocused = true }
    }

    private func add() {
        guard !trimmedName.isEmpty, !PinnedTabs.reservesName(trimmedName) else { return }
        let project = projectStore.create(name: trimmedName)
        appState.selectProject(project, in: windowState)
        dismiss()
    }
}
