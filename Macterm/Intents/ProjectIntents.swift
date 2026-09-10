import AppIntents
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ProjectIntents")

/// Add a project for a folder and select it — the folder picker's outcome,
/// without the picker.
///
/// Runs the same pair the sidebar, the Finder service and `macterm project
/// create` run (`ProjectStore.create` then `AppState.selectProject`), so a
/// matching central project file auto-applies its layout exactly as it would
/// on a first open. Always creates: a directory is not an identity, and a
/// second project on the same folder is a legitimate ask.
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

    @Parameter(title: "Name", description: "Defaults to the folder's own name.")
    var name: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Make a project from \(\.$folder)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MactermProjectEntity> {
        let ctx = try await MactermIntentHost.shared.authorizedContext()
        guard let url = folder.fileURL else {
            throw MactermIntentError.badInput("That isn't a folder on disk.")
        }
        let path = ProjectPath.canonicalLocal(url.path(percentEncoded: false))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MactermIntentError.badInput("There is no folder at \(path).")
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let target = try IntentTargets.project(project.id, in: ctx)
        // `revealProject` fronts a window ALREADY showing it rather than
        // repointing whichever window happens to be key — the rule for
        // something that happens *to* a project rather than being chosen in a
        // window (a notification click, the CLI's `pane focus`), which is
        // exactly the shape of an intent arriving from outside.
        ctx.appState.appDelegate?.showWindow()
        if target.id == PinnedTabs.projectID {
            // The sentinel must not go through the project path: its
            // first-open auto-apply would match a layout file declaring the
            // home directory.
            ctx.appState.selectPinnedProject()
        } else {
            ctx.appState.revealProject(target.id)
        }
        return .result()
    }
}
