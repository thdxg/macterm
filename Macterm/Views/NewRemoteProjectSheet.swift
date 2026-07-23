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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Remote Project")
                .font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text(host.isEmpty ? "devbox" : host))
                TextField("Host", text: $host, prompt: Text("[user@]host or ssh alias"))
                TextField("Directory", text: $directory, prompt: Text("~/dev/api"))
                TextField("zmx path (optional)", text: $zmxPath, prompt: Text("auto-detect via PATH"))
            }
            .textFieldStyle(.roundedBorder)
            Text(
                "Panes run persistent zmx sessions on the host over ssh — zmx must be installed there. "
                    + "If it isn't found automatically, set an absolute path (e.g. ~/bin/zmx or /usr/local/bin/zmx). "
                    + "Port, identity, and ControlMaster come from ~/.ssh/config."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(composedPath == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func add() {
        guard let path = composedPath else { return }
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
