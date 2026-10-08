import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "TextFiles")

/// Opening a text file in the user's terminal editor (`$VISUAL`, else
/// `$EDITOR`; Settings → General → Text Files picks a split or a tab) — a
/// ⌘-click on a path in a pane, or a file opened WITH Macterm from Finder,
/// the Dock or `open -a` (`FinderServiceProvider`).
///
/// Macterm is the file's editor only where the user made it so: `Info.plist`
/// declares text files at `Alternate` rank, so it is never anyone's default
/// until Finder's Get Info → Open with → Change All names it. A clicked file
/// therefore goes to its default app, whatever that is; only when that app is
/// Macterm does the click skip the round trip through Launch Services, which
/// is what keeps the line number — no other app can be told one.
extension AppState {
    /// A ⌘-click on a link in `pane`. Returns false for anything that isn't an
    /// existing local file — a URL, a path that names nothing, any link in a
    /// remote pane (the file is on the host) — which the caller hands to the
    /// system opener exactly as before.
    func openClickedLink(_ text: String, in pane: Pane, projects: [Project]) -> Bool {
        guard !pane.isRemote, let parsed = FileLink.parse(text) else { return false }
        let anchor = editorAnchor(for: pane)
        let link = parsed.resolved(against: (anchor?.pane ?? pane).liveLocalWorkingDirectory())
        guard TextFileOpening.isRegularFile(link.path) else { return false }
        let url = URL(fileURLWithPath: link.path)
        guard opensTextFileHere(url) else {
            // Another app opens it, and none can be told a line.
            logger.info("link: opening \(link.path, privacy: .public) with its default app")
            NSWorkspace.shared.open(url)
            return true
        }
        let placed = openTextFile(
            link.path,
            line: link.line,
            beside: pane,
            projects: projects,
            anchor: anchor
        )
        if !placed {
            // A desktop widget's pane has no split or tab to put an editor
            // in: open it the way Finder would have.
            appDelegate?.finderServices.openTextFiles([link.path], line: link.line)
        }
        return true
    }

    /// Open `path` in a new pane of `projectID` — a split of its focused pane
    /// or a tab of its own, per the setting. The Finder path, after
    /// `FinderServiceProvider` has chosen and selected the project.
    @discardableResult
    func openTextFile(_ path: String, line: Int?, inProject projectID: UUID, projects: [Project]) -> UUID? {
        let placement = textFilePlacement()
        let env = TextFileEditor.environment(path: path, line: line)
        logger.info("open: \(path, privacy: .public) in project \(projectID, privacy: .public)")
        if placement == .split,
           let pane = focusedPane(for: projectID),
           let projectDirectory = configuredProjectDirectory(projectID: projectID, projects: projects)
        {
            return splitPane(
                pane.id,
                direction: SplitDirection.auto(for: displayedSize(of: pane)),
                projectID: projectID,
                projectDirectory: projectDirectory,
                command: TextFileEditor.typedCommand,
                env: env
            )
        }
        guard let tabID = createTab(
            projectID: projectID,
            projects: projects,
            command: TextFileEditor.typedCommand,
            env: env
        )
        else { return nil }
        return workspaces[projectID]?.tabs.first { $0.id == tabID }?.focusedPaneID
    }

    /// Where an editor opened from `pane` lands: the real pane it stands for
    /// in a workspace (itself, or the pane a mirror shows — #345), or a quick
    /// terminal pane. nil for a pane in neither: a desktop widget's.
    private enum EditorAnchor {
        case workspace(projectID: UUID, pane: Pane)
        case quickTerminal(Pane)

        var pane: Pane {
            switch self {
            case let .workspace(_, pane),
                 let .quickTerminal(pane): pane
            }
        }
    }

    private func editorAnchor(for pane: Pane) -> EditorAnchor? {
        let projectID = pane.projectID
        if workspaces[projectID]?.tabs.contains(where: { $0.splitRoot.findPane(id: pane.id) != nil }) == true {
            return .workspace(projectID: projectID, pane: pane)
        }
        for window in windows {
            for (realTabID, shadow) in window.shadowTabs where shadow.splitRoot.findPane(id: pane.id) != nil {
                guard let real = workspaces[projectID]?.tabs.first(where: { $0.id == realTabID }),
                      let realID = counterpartPaneID(pane.id, from: shadow, to: real),
                      let realPane = real.splitRoot.findPane(id: realID)
                else { return nil }
                return .workspace(projectID: projectID, pane: realPane)
            }
        }
        let quickTerminal = QuickTerminalService.shared.splitState
        if let quickPane = quickTerminal.tab.splitRoot.findPane(id: pane.id) {
            return .quickTerminal(quickPane)
        }
        return nil
    }

    /// Returns false when `anchor` is nil — nowhere to put the editor.
    private func openTextFile(
        _ path: String,
        line: Int?,
        beside clicked: Pane,
        projects: [Project],
        anchor: EditorAnchor?
    ) -> Bool {
        let placement = textFilePlacement()
        let env = TextFileEditor.environment(path: path, line: line)
        let command = TextFileEditor.typedCommand
        // The pane the user clicked, which for a mirror is not the real one:
        // its own size is what they are looking at.
        let direction = SplitDirection.auto(for: clicked.nsView?.bounds.size ?? .zero)
        switch anchor {
        case let .workspace(projectID, pane):
            logger.info("link: \(path, privacy: .public) beside pane \(pane.id, privacy: .public)")
            // A pinned tab's editor always splits: a tab born pinned is
            // pinned for good, and quitting the editor would leave it behind
            // as a dimmed, unloaded row.
            if placement == .tab, projectID != PinnedTabs.projectID {
                return createTab(projectID: projectID, projects: projects, command: command, env: env) != nil
            }
            let projectDirectory = configuredProjectDirectory(projectID: projectID, projects: projects)
                ?? pane.projectPath
            return splitPane(
                pane.id,
                direction: direction,
                projectID: projectID,
                projectDirectory: projectDirectory,
                command: command,
                env: env
            ) != nil
        case let .quickTerminal(pane):
            // One tab, so always a split.
            logger.info("link: \(path, privacy: .public) beside quick terminal pane")
            return QuickTerminalService.shared.splitState.autoSplit(paneID: pane.id, command: command, env: env) != nil
        case nil:
            return false
        }
    }
}

/// The file-system and Launch Services reads behind `openClickedLink`.
enum TextFileOpening {
    static func isRegularFile(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// Whether Launch Services would hand `url` to this app — compared by
    /// bundle identifier, so a debug build defers to the installed Macterm
    /// the user chose rather than claiming its files.
    static func isDefaultApp(for url: URL) -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url),
              let ours = Bundle.main.bundleIdentifier
        else { return false }
        return Bundle(url: app)?.bundleIdentifier == ours
    }
}
