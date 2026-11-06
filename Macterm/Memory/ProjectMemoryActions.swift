import Foundation

/// Runs a memory panel action: the command in a new split beside the
/// project's focused pane, or in a new tab when the project has no pane.
///
/// The command is TYPED into the new shell (the `run:` of a layout), not
/// carried in the environment as a palette `run:` is: it was recorded from
/// the user's own shell, so it is in that shell's language (nushell, fish),
/// and it goes into that shell's history like the run it repeats.
@MainActor
enum ProjectMemoryActions {
    static func run(_ action: QuickAction, in project: Project, appState: AppState, projects: [Project]) {
        run(command: action.command, directory: action.directory, in: project, appState: appState, projects: projects)
    }

    static func run(command: String, directory: String?, in project: Project, appState: AppState, projects: [Project]) {
        // A recorded directory is a path on this Mac. A remote project's
        // terminals are on the host, so they start where the project does.
        let localDirectory = project.isRemote ? nil : existingDirectory(directory) ?? project.path
        if let pane = appState.focusedPane(for: project.id) {
            let direction = SplitDirection.auto(for: pane.nsView?.bounds.size ?? .zero)
            if let localDirectory {
                appState.splitPane(
                    pane.id,
                    direction: direction,
                    projectID: project.id,
                    command: command,
                    newPaneWorkingDirectory: localDirectory
                )
            } else {
                appState.splitPane(pane.id, direction: direction, projectID: project.id, projectDirectory: project.path, command: command)
            }
        } else if let localDirectory {
            appState.createTab(projectID: project.id, projects: projects, workingDirectory: localDirectory, command: command)
        } else {
            appState.createTab(projectID: project.id, projects: projects, command: command)
        }
    }

    private static func existingDirectory(_ path: String?) -> String? {
        guard let path else { return nil }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue ? path : nil
    }
}
