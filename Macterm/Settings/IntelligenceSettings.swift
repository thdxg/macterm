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
        // Macterm also reads it again on each activation
        // (`ProjectMemory.attach`): the user turns Apple Intelligence on in
        // System Settings.
        .onAppear { ProjectMemory.shared.refreshModelAvailability() }
        .confirmationDialog("Forget the insights of all projects?", isPresented: $isConfirmingForgetAll) {
            Button("Forget All", role: .destructive) { ProjectMemory.shared.forgetAll() }
        } message: {
            Text("Macterm deletes every command that it recorded. You cannot undo this.")
        }
    }

    /// Project Insights needs Apple Intelligence. Without it the toggle is
    /// disabled and shows off, and `Preferences.projectMemory` keeps the
    /// user's choice for when Apple Intelligence is back.
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
            localized: "Shows where you left off in each project, its Git branches and the commands to run next."
        )
        guard !modelIsAvailable else { return description }
        return String(
            localized: "settings.intelligence.projectInsights.unavailableCaption",
            defaultValue: "\(description) \(modelStatus).",
            comment: "The description of Project Insights, then the reason that it is not available."
        )
    }

    private var modelStatus: String {
        switch ProjectMemory.shared.modelAvailability {
        case .available: String(localized: "Available")
        case .notReady: String(localized: "Turn on Apple Intelligence in System Settings")
        case .unsupported: String(localized: "Not available on this Mac")
        }
    }
}
