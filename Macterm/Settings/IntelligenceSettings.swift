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
                header
            }

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
                Text("Project Insights")
            }

            Section("Apple Intelligence") {
                LabeledContent("On-device model") {
                    Text(modelStatus)
                }
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

    /// The block at the top of the pane, in the shape of the one at the top
    /// of a System Settings pane: the symbol, the pane's name, and what every
    /// feature below has in common, with a link to the docs. The sections
    /// below do not say it again. It links the Project Insights page, the
    /// only feature in the pane, so that section has no docs button of its
    /// own.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 26))
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Intelligence", comment: "Settings pane"))
                Text(headerCaption)
                    .settingsCaption()
            }
        }
        .padding(.vertical, 4)
    }

    /// The caption, then the docs link as its own phrase, as System Settings
    /// ends its block with "Learn more…".
    private var headerCaption: AttributedString {
        var caption = AttributedString(String(
            localized: "These features need Apple Intelligence. Apple's on-device model does all the work, so nothing leaves this Mac."
        ))
        var link = AttributedString(String(localized: "Learn more…"))
        link.link = DocsSection.projectInsights.url
        caption.append(AttributedString(" "))
        caption.append(link)
        return caption
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
