import SwiftUI

/// Settings → Intelligence: the features that learn from what the user does,
/// and Apple Intelligence. Listed only on macOS 26 and later
/// (`SettingsPane.visible`).
struct IntelligenceSettings: View {
    @State
    private var preferences = Preferences.shared
    @State
    private var isConfirmingForgetAll = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable Project Insights", isOn: $preferences.projectMemory)
                Text("Shows where you left off in each project, its Git branches and the commands to run next.")
                    .settingsCaption()
                Group {
                    Toggle(isOn: $preferences.projectMemorySummary) {
                        Text("Summarize with Apple Intelligence").dimsWhenDisabled()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A short paragraph at the top of the panel says where you left off.")
                        Text("Apple's on-device model writes it. Nothing leaves this Mac.")
                    }
                    .settingsCaption()
                }
                .disabled(!preferences.projectMemory)
                .padding(.leading, 16)
                HStack {
                    Text("Recorded commands")
                    Spacer()
                    Button("Forget All…", role: .destructive) { isConfirmingForgetAll = true }
                }
            } header: {
                DocsSectionHeader("Project Insights", docs: .projectInsights)
            }

            Section("Apple Intelligence") {
                LabeledContent("On-device model") {
                    Text(modelStatus)
                }
                Text("Every feature that uses a model uses Apple's on-device model. Nothing leaves this Mac.")
                    .settingsCaption()
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget the insights of all projects?", isPresented: $isConfirmingForgetAll) {
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
