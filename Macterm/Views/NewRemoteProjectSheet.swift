import SwiftUI

/// "New Project → Remote Machine" (#104): collects a display name, an ssh
/// destination (`[user@]host` or an ssh-config alias — port/identity/
/// ControlMaster live in `~/.ssh/config`), and a remote directory, composing
/// them into the scp-style `Project.path`. Validation is `ProjectPath`'s:
/// the Add button enables only when the fields form a well-formed remote
/// spec. No connection probe here — the first pane's ssh is the probe, and
/// its failure output renders right in the pane.
struct NewRemoteProjectSheet: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore
    @Environment(\.dismiss)
    private var dismiss

    @State
    private var name = ""
    @State
    private var host = ""
    @State
    private var directory = "~"
    @State
    private var zmxPath = ""

    private var composedPath: String? {
        ProjectPath.composeRemote(host: host, directory: directory)
    }

    private var trimmedZmxPath: String? {
        let t = zmxPath.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// A typed name a sentinel workspace reserves: refused here like every
    /// typed name (`Project.reservedNameMessage`). An empty field falls back
    /// to the host, which nobody typed as a name, so `ProjectStore.create`
    /// suffixes that one instead.
    private var reservedNameMessage: String? {
        Project.reservedNameMessage(for: name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Remote Project")
                .font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text(verbatim: host.isEmpty ? "devbox" : host))
                TextField("Host", text: $host, prompt: Text("[user@]host or ssh alias"))
                TextField("Directory", text: $directory, prompt: Text(verbatim: "~/dev/api"))
                TextField("zmx path (optional)", text: $zmxPath, prompt: Text("find it in PATH"))
            }
            .textFieldStyle(.roundedBorder)
            if let reservedNameMessage {
                Text(reservedNameMessage)
                    .font(.caption)
                    .foregroundStyle(MactermTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("""
            Each pane is a persistent zmx session on the host, over ssh. zmx must be installed there. \
            If Macterm cannot find it, set an absolute path, for example ~/bin/zmx or /usr/local/bin/zmx. \
            Port, identity and ControlMaster come from ~/.ssh/config.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(composedPath == nil || reservedNameMessage != nil)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func add() {
        guard let path = composedPath, reservedNameMessage == nil else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        // Always create: a directory can back several projects, so a repeat
        // host:dir here adds a distinct project rather than reusing the last.
        let project = projectStore.create(
            name: trimmedName.isEmpty ? host.trimmingCharacters(in: .whitespaces) : trimmedName,
            path: path,
            zmxPath: trimmedZmxPath
        )
        appState.selectProject(project)
        dismiss()
    }
}
