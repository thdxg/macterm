import SwiftUI

/// Install or update Macterm's zmx build on the host of a remote project
/// (#699). Opened from Settings → Projects (the row menu of a remote
/// project) and from the New Remote Project sheet. It checks the host when
/// it opens, says what it found, and installs only on a click. Every
/// connection runs under a pty, so a host that asks for a password or a
/// host key asks here (`RemoteZmxInstallFlow`).
struct ZmxInstallSheet: View {
    @Environment(\.dismiss)
    private var dismiss

    @State
    private var flow: RemoteZmxInstallFlow
    @State
    private var answer = ""

    /// Called after a successful install with the installed path, when the
    /// project's `zmxPath` should name it (`installedPathDiffersFromProjectZmx`).
    private let onInstalled: (String) -> Void

    init(request: ZmxInstallRequest, onInstalled: @escaping (String) -> Void) {
        _flow = State(initialValue: RemoteZmxInstallFlow(request: request))
        self.onInstalled = onInstalled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            facts
            if let prompt = flow.prompt {
                promptField(prompt)
            }
            if flow.phase != .checked || !flow.log.isEmpty {
                logView
            }
            if let failure = flow.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(MactermTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(20)
        .frame(width: 460)
        .task { await flow.check() }
        .onDisappear { flow.cancel() }
    }

    private var title: String {
        switch flow.offer {
        case .update: String(localized: "Update zmx on \(flow.request.hostName)")
        default: String(localized: "Install zmx on \(flow.request.hostName)")
        }
    }

    // MARK: - What the check found

    @ViewBuilder
    private var facts: some View {
        switch flow.phase {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking the host…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .checked,
             .downloading,
             .uploading,
             .installing,
             .done,
             .failed:
            if let state = flow.hostState {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Host").foregroundStyle(.secondary)
                        Text(verbatim: "\(state.system) \(state.machine)")
                    }
                    GridRow {
                        Text("zmx on the host").foregroundStyle(.secondary)
                        Text(verbatim: hostZmxDescription(state))
                    }
                    GridRow {
                        Text("Macterm's build").foregroundStyle(.secondary)
                        Text(verbatim: flow.release?.tag ?? "—")
                    }
                    if let path = flow.installedPath {
                        GridRow {
                            Text("Installed").foregroundStyle(.secondary)
                            Text(verbatim: path)
                        }
                    }
                }
                .font(.callout)
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func hostZmxDescription(_ state: ZmxHostState) -> String {
        guard let path = state.zmxPath else { return String(localized: "none") }
        guard let version = state.version else { return path }
        let build = version.forkTag.map { "+thdxg.\($0)" } ?? ""
        return "\(path) (\(version.upstream)\(build))"
    }

    private var explanation: String {
        switch flow.phase {
        case .done:
            return String(localized: """
            Done. New tabs and splits use this zmx. A session that is running keeps its old daemon \
            until you create it again.
            """)
        case .downloading:
            return String(localized: "Getting the binary and checking its checksum…")
        case .uploading:
            return String(localized: "Copying the binary to the host…")
        case .installing:
            return String(localized: "Moving it into place on the host…")
        default:
            break
        }
        guard let verdict = flow.verdict else { return "" }
        switch verdict {
        case .missing,
             .upstream,
             .otherBuild:
            // The release carries no binary for this host's target (a
            // release from before the Linux assets): say so, rather than
            // name a button that is not there.
            if flow.offer == nil {
                return String(localized: "This Macterm build has no zmx binary for \(flow.hostState?.target?.displayName ?? "").")
            }
        default:
            break
        }
        switch verdict {
        case let .unsupported(system, machine):
            return String(localized: "Macterm has no zmx build for \(system) on \(machine).")
        case .missing:
            return String(localized: """
            The host has no zmx. Macterm's build goes to ~/.local/bin/zmx, which its panes find. \
            Nothing on the host is changed before you click Install.
            """)
        case .upstream:
            return String(localized: """
            The host runs the upstream zmx. Macterm's build has the fixes that its remote panes rely on. \
            It goes to ~/.local/bin/zmx. Nothing on the host is changed before you click Update.
            """)
        case .otherBuild:
            return String(localized: """
            The host runs another build of Macterm's zmx. The pinned build goes to ~/.local/bin/zmx. \
            Nothing on the host is changed before you click Update.
            """)
        case .current:
            return String(localized: "The host already runs the build this Macterm pins.")
        }
    }

    // MARK: - A prompt of the connection

    private func promptField(_ prompt: SSHPrompt) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            switch prompt {
            case let .secret(line):
                Text(verbatim: line)
                    .font(.callout)
                SecureField("Password or passphrase", text: $answer)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
            case let .yesNo(line):
                Text(verbatim: line)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("No") { answer = "no"
                        send()
                    }
                    Button("Yes") { answer = "yes"
                        send()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(10)
        .background(MactermTheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func send() {
        let text = answer
        answer = ""
        flow.answerPrompt(text)
    }

    // MARK: - The connection's output

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(verbatim: flow.log.isEmpty ? " " : flow.log)
                    .font(.terminal(.caption))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .id("end")
            }
            .frame(height: 120)
            .background(MactermTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .onChange(of: flow.log) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack {
            Spacer()
            switch flow.phase {
            case .done:
                Button("Done") {
                    if flow.installedPathDiffersFromProjectZmx, let path = flow.installedPath {
                        onInstalled(path)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            case .failed:
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { Task { await flow.check() } }
                    .keyboardShortcut(.defaultAction)
            case .checking,
                 .downloading,
                 .uploading,
                 .installing:
                Button("Cancel", role: .cancel) {
                    flow.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            case .checked:
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let offer = flow.offer {
                    Button(offer == .update ? "Update" : "Install") { Task { await flow.install() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
