import SwiftUI

/// Settings → Intelligence: the features that learn from what the user does,
/// and Apple Intelligence. Listed only on macOS 26 and later
/// (`SettingsPane.visible`).
struct IntelligenceSettings: View {
    /// Observed directly: the panel's Turn On button writes the same
    /// preference while this pane is open.
    @State
    private var preferences = Preferences.shared
    @State
    private var isConfirmingForgetAll = false

    var body: some View {
        Form {
            Section {
                Toggle("Record commands for project memory", isOn: $preferences.projectMemory)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Macterm records each command that finishes in a project: the command, its folder, its exit code and its time.")
                    Text("For a command that fails, it also records the last lines of its output.")
                    Text("It removes secrets first and keeps the records on this Mac only. The project memory panel shows them.")
                }
                .settingsCaption()
                HStack {
                    Text("Recorded commands")
                    Spacer()
                    Button("Forget All…", role: .destructive) { isConfirmingForgetAll = true }
                }
            } header: {
                DocsSectionHeader("Project Memory", docs: .projectMemory)
            }

            Section("Apple Intelligence") {
                LabeledContent("On-device model") {
                    Text(modelStatus)
                }
                Text("Explain Output uses Apple's on-device model. Nothing leaves this Mac.")
                    .settingsCaption()
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget the memory of all projects?", isPresented: $isConfirmingForgetAll) {
            Button("Forget All", role: .destructive) { ProjectMemory.shared.forgetAll() }
        } message: {
            Text("Macterm deletes every command that it recorded. You cannot undo this.")
        }
    }

    private var modelStatus: String {
        switch OnDeviceModel.availability {
        case .available: String(localized: "Available")
        case .notReady: String(localized: "Turn on Apple Intelligence in System Settings")
        case .unsupported: String(localized: "Not available on this Mac")
        }
    }
}
