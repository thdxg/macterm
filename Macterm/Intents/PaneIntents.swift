import AppIntents
import os

private let logger = Logger(subsystem: appBundleID, category: "PaneIntents")

/// Type a command into a pane's live shell.
///
/// Goes through `GhosttyTerminalNSView.sendText` — the paste path, the same one
/// `macterm pane run` uses — so it reaches a shell that is already up, unlike
/// New Tab's spawn-time command. The trailing newline is what submits it, and
/// "Submit" withholding exactly that character is the whole difference between
/// running a command and leaving it on the prompt for a person to read (or for
/// a TUI that submits on its own terms).
struct RunCommandInMactermPaneIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Command in Pane"
    static let description = IntentDescription("Type a command into a pane's shell.")

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = [.background, .foreground]
    #endif

    @Parameter(
        title: "Command",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none,
            multiline: true,
            autocorrect: false,
            smartQuotes: false,
            smartDashes: false
        )
    )
    var command: String

    @Parameter(title: "Pane")
    var pane: MactermPaneEntity

    @Parameter(
        title: "Submit",
        description: "Off leaves the text on the prompt without running it.",
        default: true
    )
    var submit: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command) in \(\.$pane)") {
            \.$submit
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let ctx = try await MactermIntentHost.shared.authorizedContext()
        guard !command.isEmpty else {
            throw MactermIntentError.badInput("The command is empty.")
        }
        let target = try IntentTargets.pane(session: pane.id, in: ctx)
        guard let view = target.pane.nsView,
              view.sendText(submit ? command + "\n" : command)
        else {
            throw MactermIntentError.noSurface
        }
        // Injected input makes zmx hand this client leadership (its
        // `isUserInput` rule) with no focus change to notice it by — record it,
        // or the non-leader dim points at the wrong mirror.
        ctx.appState.noteSessionLeader(target.pane)
        logger.info("intent: ran a command in \(target.pane.sessionName, privacy: .public)")
        return .result()
    }
}

/// Send a single key chord to a pane.
///
/// Rides libghostty's key-*encoding* path (`sendKey`), not the paste path, so
/// it can deliver control bytes (`ctrl+c`) and named keys (`escape`, `up`) that
/// have no text form at all — which is why it is a separate action from Run
/// Command rather than a flag on it. The chord grammar is the one the user's
/// own keybinds use (`HotkeyRegistry.parseShortcut`).
///
/// This bypasses `keyDown` entirely, so anything intercepting there does not
/// apply — the two key-input paths share no gate.
struct SendKeyToMactermPaneIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Key"
    static let description = IntentDescription("Send one key chord to a pane, like ctrl+c, escape, or up.")

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = [.background, .foreground]
    #endif

    @Parameter(
        title: "Key",
        description: "A chord like ctrl+c, escape, up, or a bare printable like j.",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none,
            autocorrect: false,
            smartQuotes: false,
            smartDashes: false
        )
    )
    var key: String

    @Parameter(title: "Pane")
    var pane: MactermPaneEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$key) to \(\.$pane)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let ctx = try await MactermIntentHost.shared.authorizedContext()
        guard let shortcut = HotkeyRegistry.parseShortcut(key) else {
            throw MactermIntentError.badInput("\"\(key)\" isn't a key chord. Try ctrl+c, escape, or up.")
        }
        let target = try IntentTargets.pane(session: pane.id, in: ctx)
        guard let view = target.pane.nsView,
              view.sendKey(keyCode: shortcut.keyCode, mods: shortcut.modifiers)
        else {
            throw MactermIntentError.noSurface
        }
        ctx.appState.noteSessionLeader(target.pane)
        logger.info("intent: sent \(key, privacy: .public) to \(target.pane.sessionName, privacy: .public)")
        return .result()
    }
}

/// Read a pane's terminal text — the viewport, or the whole scrollback.
///
/// Reads libghostty's own cell text (`ghostty_surface_read_text`), the same
/// source as `macterm pane dump`, so it sees what a full-screen TUI is showing
/// as well as ordinary output that could have been piped.
struct GetMactermPaneContentsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Pane Contents"
    static let description = IntentDescription("Read the text a pane is showing.")

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .background
    #endif

    @Parameter(title: "Pane")
    var pane: MactermPaneEntity

    @Parameter(
        title: "Include Scrollback",
        description: "Off reads only what is on screen.",
        default: false
    )
    var scrollback: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Get the contents of \(\.$pane)") {
            \.$scrollback
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let ctx = try await MactermIntentHost.shared.authorizedContext()
        let target = try IntentTargets.pane(session: pane.id, in: ctx)
        guard let view = target.pane.nsView, let text = view.readText(scrollback: scrollback) else {
            throw MactermIntentError.noSurface
        }
        return .result(value: text)
    }
}

/// Which fact about a pane Get Pane Details returns.
///
/// One action over an enum rather than five actions or five return values,
/// mirroring Ghostty's Get Details of Terminal: a shortcut wants one string it
/// can feed into the next step, and a multi-field return would make every
/// consumer index into a dictionary.
enum MactermPaneDetail: String, AppEnum {
    case id
    case session
    case workingDirectory
    case foregroundProcess
    case size

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Pane Detail")

    static let caseDisplayRepresentations: [MactermPaneDetail: DisplayRepresentation] = [
        .id: "ID",
        .session: "Session Name",
        .workingDirectory: "Working Directory",
        .foregroundProcess: "Foreground Process",
        .size: "Size",
    ]
}

/// Read one fact about a pane.
struct GetMactermPaneDetailsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Pane Details"
    static let description = IntentDescription("Read a pane's id, session, directory, process, or size.")

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .background
    #endif

    @Parameter(title: "Detail")
    var detail: MactermPaneDetail

    @Parameter(title: "Pane")
    var pane: MactermPaneEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$detail) from \(\.$pane)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String?> {
        let ctx = try await MactermIntentHost.shared.authorizedContext()
        let target = try IntentTargets.pane(session: pane.id, in: ctx)
        return .result(value: Self.value(of: detail, for: target.pane))
    }

    /// Pure so the mapping is testable without an intent runtime. A nil answer
    /// is a real result ("no surface yet", "no process sampled"), not a
    /// failure — an unpopulated field is what a shortcut branches on.
    @MainActor
    static func value(of detail: MactermPaneDetail, for pane: Pane) -> String? {
        switch detail {
        case .id: pane.id.uuidString
        case .session: pane.sessionName
        // The live pwd (shell integration) with the project's own path as the
        // fallback — the same pair `pane list` reports.
        case .workingDirectory: pane.nsView?.currentPwd ?? pane.projectPath
        case .foregroundProcess: pane.foregroundProcessName
        case .size: pane.nsView?.surfaceSize.map { "\($0.columns)x\($0.rows)" }
        }
    }
}

/// Focus a pane — select its tab, front its window, and give it first
/// responder.
struct FocusMactermPaneIntent: AppIntent {
    static let title: LocalizedStringResource = "Focus Pane"
    static let description = IntentDescription("Show a pane and put the keyboard in it.")

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static let supportedModes: IntentModes = .background
    #endif

    @Parameter(title: "Pane")
    var pane: MactermPaneEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Focus \(\.$pane)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let ctx = try await MactermIntentHost.shared.authorizedContext()
        let target = try IntentTargets.pane(session: pane.id, in: ctx)
        ctx.appState.appDelegate?.showWindow()
        // `navigateToPane` selects the containing tab, fronts the window and
        // restores first responder — everything "focus" means for a person.
        ctx.appState.navigateToPane(target.pane.id, projectID: target.projectID)
        return .result()
    }
}
