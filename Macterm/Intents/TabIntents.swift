import AppIntents
import os

private let logger = Logger(subsystem: appBundleID, category: "TabIntents")

/// Open a tab in a project, optionally running a command in it.
///
/// The command is spawn-time `initial_input` — the layout `run:` path, the same
/// one `macterm tab new --run` takes — not a paste into a shell that is already
/// up. That is what lets it run through the user's own login shell with their
/// full environment, and it means the command must tokenize in whatever shell
/// they use.
struct NewMactermTabIntent: AppIntent {
    static let title: LocalizedStringResource = "New Tab"
    static let description = IntentDescription("Open a tab in a project, optionally running a command.")

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .background
    #endif

    @Parameter(title: "Project")
    var project: MactermProjectEntity

    @Parameter(
        title: "Command",
        description: "Typed into the new tab's shell when it starts. Leave empty for a plain shell.",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none,
            autocorrect: false,
            smartQuotes: false,
            smartDashes: false
        )
    )
    var command: String?

    static var parameterSummary: some ParameterSummary {
        Summary("New tab in \(\.$project)") {
            \.$command
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<MactermTabEntity> {
        let ctx = try await MactermIntentHost.shared.authorizedContext()
        let target = try IntentTargets.project(project.id, in: ctx)
        // The tab is created in a project that may not be the one on screen,
        // and from outside the app nothing has fronted a window at all — front
        // one first so `createTab`'s selection lands somewhere visible, the
        // same preparation a Dock-menu New Tab does.
        ctx.appState.appDelegate?.showWindow()
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tabID = ctx.appState.createTab(
            projectID: target.id,
            projects: ctx.projectStore.projects,
            command: trimmed?.isEmpty == false ? trimmed : nil
        ),
            let tab = ctx.appState.workspaces[target.id]?.tabs.first(where: { $0.id == tabID })
        else {
            throw MactermIntentError.notFound
        }
        logger.info("intent: new tab in \(target.name, privacy: .public)")
        return .result(value: MactermTabEntity(tab, projectID: target.id, in: ctx))
    }
}

/// Select a tab and bring its window forward.
struct FocusMactermTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Focus Tab"
    static let description = IntentDescription("Show a tab and bring its window forward.")

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .background
    #endif

    @Parameter(title: "Tab")
    var tab: MactermTabEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Focus \(\.$tab)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let ctx = try await MactermIntentHost.shared.authorizedContext()
        let (projectID, target) = try IntentTargets.tab(tab.id, in: ctx)
        ctx.appState.appDelegate?.showWindow()
        // Selecting the tab's project first: a tab in a project no window is
        // showing would otherwise be selected into a workspace nobody is
        // looking at.
        if projectID == PinnedTabs.projectID {
            ctx.appState.selectPinnedProject()
        } else {
            ctx.appState.revealProject(projectID)
        }
        ctx.appState.selectTab(target.id, projectID: projectID)
        return .result()
    }
}

/// Close a tab — sessions and all.
///
/// A busy tab is refused with `.busy` rather than staging the app's
/// confirmation dialog: a shortcut can run unattended and a modal nobody
/// answers hangs the automation. Same contract as `macterm tab close` without
/// `--force`. (There is deliberately no force flag: "close it even though
/// something is running" is a judgement about work in progress, and a shortcut
/// is the wrong place to pre-commit to it.)
struct CloseMactermTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Close Tab"
    static let description = IntentDescription("Close a tab and end its sessions. Refuses if a program is running.")

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .background
    #endif

    @Parameter(title: "Tab")
    var tab: MactermTabEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Close \(\.$tab)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let ctx = try await MactermIntentHost.shared.authorizedContext()
        let (projectID, target) = try IntentTargets.tab(tab.id, in: ctx)
        // The same expression `AppState.requestCloseTab` evaluates before it
        // decides to ask, so an intent refuses exactly when the app would have
        // put a dialog up.
        guard !target.splitRoot.allPanes().contains(where: \.needsConfirmClose) else {
            throw MactermIntentError.busy
        }
        logger.info("intent: close tab \(target.sidebarTitle, privacy: .public)")
        // Closing a PINNED tab is an unload, not a removal — `closeTab` routes
        // that itself, so one call serves both.
        ctx.appState.closeTab(target.id, projectID: projectID)
        return .result()
    }
}
