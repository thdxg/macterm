import AppIntents
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ProjectIntents")

/// Add a project for a folder and select it — the folder picker's outcome,
/// without the picker.
///
/// Runs the same pair the sidebar, the Finder service and `macterm project
/// create` run (`ProjectStore.create` then `AppState.selectProject`). Always
/// creates: a directory is not an identity, and a second project on the same
/// folder is a legitimate ask.
struct NewMactermProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "New Project"
    static let description = IntentDescription("Add a folder as a project and select it.")

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .background
    #endif

    /// `supportedTypeIdentifiers:` rather than `supportedContentTypes:`,
    /// which is macOS 15 only — the deployment target is 14, and gating the
    /// whole intent (what Ghostty does for its own New Terminal) would hide
    /// the action from every Sonoma install. Same UTI either way.
    @Parameter(title: "Folder", supportedTypeIdentifiers: ["public.folder"])
    var folder: IntentFile

    @Parameter(title: "Name", description: "The default is the name of the folder.")
    var name: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Make a project from \(\.$folder)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MactermProjectEntity> {
        let ctx = try await MactermIntentHost.shared.authorizedContext()
        guard let url = folder.fileURL else {
            throw MactermIntentError.badInput(String(localized: "That is not a folder on the disk."))
        }
        let path = ProjectPath.canonicalLocal(url.path(percentEncoded: false))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MactermIntentError.badInput(String(localized: "There is no folder at \(path)."))
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        // A typed name is refused like the CLI's `--name`; the folder's own
        // name is `ProjectStore.create`'s to disambiguate.
        if let trimmed, let message = Project.reservedNameMessage(for: trimmed) {
            throw MactermIntentError.badInput(message)
        }
        logger.info("intent: new project at \(path, privacy: .public)")
        let project = ctx.projectStore.create(
            name: (trimmed?.isEmpty == false ? trimmed : nil) ?? (path as NSString).lastPathComponent,
            path: path
        )
        ctx.appState.selectProject(project)
        // The shortcut ran from outside the app, so nothing has fronted a
        // window — and this one's whole point is to show the user their new
        // project. Same call the Finder service makes, for the same reason.
        ctx.appState.appDelegate?.showWindow()
        return .result(value: MactermProjectEntity(project))
    }
}

/// Select a project — the sidebar click.
struct FocusMactermProjectIntent: AppIntent {
    static let title: LocalizedStringResource = "Focus Project"
    static let description = IntentDescription("Show a project and bring its window forward.")

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .background
    #endif

    @Parameter(title: "Project")
    var project: MactermProjectEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Focus \(\.$project)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let ctx = try await MactermIntentHost.shared.authorizedContext()
        try IntentTargets.focusProject(project.id, in: ctx)
        return .result()
    }
}

/// Open a project from a Spotlight result — Focus Project, as the
/// `OpenIntent` that Spotlight runs for an indexed `MactermProjectEntity`.
///
/// A separate intent and not a conformance on `FocusMactermProjectIntent`:
/// `OpenIntent` requires the parameter to be named `target`, and a saved
/// shortcut stores its parameters by name, so renaming Focus Project's
/// `project` would empty it in every shortcut that uses it. Hidden from the
/// Shortcuts gallery, which already offers Focus Project.
struct OpenMactermProjectIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Project"
    static let description = IntentDescription("Show a project and bring its window forward.")
    static let isDiscoverable = false

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .background
    #endif

    @Parameter(title: "Project")
    var target: MactermProjectEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let ctx = try await MactermIntentHost.shared.authorizedContext()
        try IntentTargets.focusProject(target.id, in: ctx)
        return .result()
    }
}
