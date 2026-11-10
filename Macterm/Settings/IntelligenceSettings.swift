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
                Group {
                    Toggle(isOn: projectInsights) {
                        Text("Enable Project Insights").dimsWhenDisabled()
                    }
                    Text(projectInsightsCaption)
                        .settingsCaption()
                }
                .disabled(!modelIsAvailable)
                LabeledContent("Recorded commands") {
                    HStack {
                        Text(recordedCommands)
                        Button("Forget All…", role: .destructive) { isConfirmingForgetAll = true }
                    }
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
        // Macterm also reads it again on each activation
        // (`ProjectMemory.attach`): the user turns Apple Intelligence on in
        // System Settings.
        .onAppear {
            ProjectMemory.shared.refreshModelAvailability()
            ProjectMemory.shared.store.prepareAll()
        }
        .confirmationDialog("Forget the insights of all projects?", isPresented: $isConfirmingForgetAll) {
            Button("Forget All", role: .destructive) { ProjectMemory.shared.forgetAll() }
        } message: {
            Text("Macterm deletes every command that it recorded. You cannot undo this.")
        }
    }

    /// Project Insights needs Apple Intelligence. Without it the toggle is
    /// disabled, dimmed and off, its caption ends with the reason, and
    /// `Preferences.projectMemory` keeps the user's choice for when Apple
    /// Intelligence is back.
    private var modelIsAvailable: Bool {
        ProjectMemory.shared.modelAvailability == .available
    }

    private var projectInsights: Binding<Bool> {
        Binding(
            get: { modelIsAvailable && preferences.projectMemory },
            set: { preferences.projectMemory = $0 }
        )
    }

    /// The description, and after it the reason when the model is not
    /// available, in one caption.
    private var projectInsightsCaption: String {
        let description = String(
            localized: "Shows where you left off in each project, its Git branches, and the commands to run next."
        )
        guard !modelIsAvailable else { return description }
        return String(
            localized: "settings.intelligence.projectInsights.unavailableCaption",
            defaultValue: "\(description) \(modelStatus).",
            comment: "The description of Project Insights, then the reason that it is not available."
        )
    }

    /// The count of the recorded commands that Macterm can read, also
    /// while Project Insights is off: older records stay on disk.
    private var recordedCommands: String {
        let count = ProjectMemory.shared.store.recordedCommandCount
        guard count > 0 else {
            return String(
                localized: "settings.intelligence.recordedCommands.none",
                defaultValue: "None",
                comment: "Macterm has recorded no commands."
            )
        }
        return String(localized: "\(count) commands", comment: "The number of commands that Project Insights recorded.")
    }

    private var modelStatus: String {
        switch ProjectMemory.shared.modelAvailability {
        case .available: String(localized: "Available")
        case .notReady: String(localized: "Turn on Apple Intelligence in System Settings")
        case .unsupported: String(localized: "Not available on this Mac")
        }
    }
}
