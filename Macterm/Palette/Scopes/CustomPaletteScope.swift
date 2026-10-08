import AppKit
import Foundation

/// One screen of a custom palette: which palette, which node, what the rows
/// above exported, and the pill naming it — the row that was picked to get
/// here. Two frames of one node under different selections are different
/// targets, which is what lets `Pods` be reached from the root and from a
/// namespace alike.
struct CustomPaletteTarget: Hashable {
    let paletteID: String
    let node: String
    let exports: [String: String]
    let pill: PalettePill

    func entering(_ node: String, pill: PalettePill, adding exports: [String: String]) -> CustomPaletteTarget {
        CustomPaletteTarget(
            paletteID: paletteID,
            node: node,
            exports: self.exports.merging(exports) { _, new in new },
            pill: pill
        )
    }
}

/// A custom palette's screen (`CustomPaletteFile`). A menu node lists its
/// items at once; a listing node runs its command once on `activate`, in
/// bash or its `#!` interpreter (`CustomPaletteScript`) with the target's
/// exports in the environment,
/// reports `loading` meanwhile, keeps the rows and filters them per
/// keystroke. A command that fails — not found, non-zero, output that isn't
/// the shape asked for — becomes `failure`, retried with ⌘R.
@MainActor
final class CustomPaletteScope: PaletteScope {
    let target: CustomPaletteTarget
    private let runner: CustomPaletteCommandRunner

    private(set) var loading: PaletteLoading?
    private(set) var failure: PaletteFailure?
    private var rows: [CustomPaletteRow]?
    private var task: Task<Void, Never>?
    private var onChange: (@MainActor () -> Void)?
    private var context: PaletteContext?

    init(target: CustomPaletteTarget, runner: @escaping CustomPaletteCommandRunner = CustomPaletteRunner.run) {
        self.target = target
        self.runner = runner
    }

    private func palette(_ context: PaletteContext) -> CustomPalette? {
        context.appState.customPalettes.palette(id: target.paletteID)
    }

    private func node(_ context: PaletteContext) -> CustomPalette.Node? {
        palette(context)?.nodes[target.node]
    }

    var placeholder: String {
        if let context, let placeholder = node(context)?.placeholder { return placeholder }
        return "Search \(target.pill.title)..."
    }

    func activate(context: PaletteContext, onChange: @escaping @MainActor () -> Void) {
        self.context = context
        self.onChange = onChange
        guard fileReads(context) else { return }
        guard node(context)?.listing != nil, rows == nil, task == nil, failure == nil else { return }
        startListing()
    }

    /// Whether the palette's file read: a file that didn't is this screen's
    /// `failure`, named after the file with the validator's diagnosis, so
    /// entering a broken palette shows what is wrong with it.
    private func fileReads(_ context: PaletteContext) -> Bool {
        guard let entry = context.appState.customPalettes.entry(id: target.paletteID) else {
            failure = PaletteFailure(title: "This palette's file is gone", detail: nil)
            return false
        }
        if let error = entry.failure {
            failure = PaletteFailure(title: "Couldn't read \(entry.fileURL.lastPathComponent)", detail: error.localizedDescription)
            return false
        }
        return true
    }

    func deactivate() {
        task?.cancel()
        task = nil
    }

    func retry() {
        guard task == nil else { return }
        failure = nil
        // The file may have been fixed since: read it again before deciding
        // whether there is a listing to run.
        if let context {
            context.appState.customPalettes.reload()
            guard fileReads(context) else {
                onChange?()
                return
            }
            guard node(context)?.listing != nil else {
                onChange?()
                return
            }
        }
        startListing()
    }

    private func startListing() {
        guard let context, let palette = palette(context), let listing = palette.nodes[target.node]?.listing else { return }
        let environment = Self.environment(for: target, context: context)
        let invocation = CustomPaletteScript.invocation(of: listing.command)
        let requires = palette.requires
        let cwd = Self.projectDirectory(context)
        let runner = runner
        let title = target.pill.title
        loading = PaletteLoading(message: "Listing \(title)…")
        onChange?()
        task = Task { @MainActor [weak self] in
            var outcome: Result<[CustomPaletteRow], PaletteFailure>
            do {
                let result = try await runner(invocation.line, environment.merging(invocation.environment) { _, new in new }, cwd)
                outcome = Self.rows(from: result, listing: listing, title: title)
                if result.status != 0 {
                    let missing = await CustomPaletteRequirements.missing(
                        requires, environment: environment, currentDirectory: cwd, runner: runner
                    )
                    if !missing.isEmpty {
                        outcome = .failure(PaletteFailure(
                            title: "Couldn't list \(title)",
                            detail: CustomPaletteRequirements.message(missing: missing)
                        ))
                    }
                }
            } catch is CustomPaletteRunner.TimedOut {
                outcome = .failure(PaletteFailure(
                    title: "Couldn't list \(title)",
                    detail: "The command didn't finish within \(CustomPaletteRunner.timeout.components.seconds) seconds."
                ))
            } catch {
                outcome = .failure(PaletteFailure(title: "Couldn't list \(title)", detail: error.localizedDescription))
            }
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            self.loading = nil
            switch outcome {
            case let .success(rows): self.rows = rows
            case let .failure(failure): self.failure = failure
            }
            self.onChange?()
        }
    }

    /// The rows a command's result yields, or why it yields none. Pure:
    /// `CustomPaletteScopeTests` drives every shape through it.
    static func rows(
        from result: CustomPaletteCommandResult,
        listing: CustomPalette.Listing,
        title: String
    ) -> Result<[CustomPaletteRow], PaletteFailure> {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0 else {
            return .failure(PaletteFailure(
                title: "Couldn't list \(title)",
                detail: stderr.isEmpty ? "The command exited with status \(result.status)." : stderr
            ))
        }
        do {
            return try .success(CustomPaletteRows.parse(output: result.stdout, listing: listing))
        } catch let failure as CustomPaletteRows.Failure {
            let detail = switch failure {
            case let .notJSON(reason): "Output isn't JSON: \(reason)"
            case let .rowsNotFound(path): "Nothing at rows: \(path) in the output"
            case let .rowsNotAnArray(path): "rows: \(path) isn't an array"
            case let .plainOutputWithRowsPath(path): "rows: \(path) names a path, but the output isn't JSON"
            }
            return .failure(PaletteFailure(title: "Couldn't read \(title)", detail: stderr.isEmpty ? detail : "\(detail)\n\(stderr)"))
        } catch {
            return .failure(PaletteFailure(title: "Couldn't read \(title)", detail: error.localizedDescription))
        }
    }

    func sections(for query: PaletteQuery, context: PaletteContext) -> [PaletteSection] {
        self.context = context
        guard fileReads(context), let palette = palette(context) else { return [] }
        guard let node = palette.nodes[target.node] else {
            return [PaletteSection(header: nil, items: [
                PaletteItem(
                    id: "custom-missing-node",
                    title: "No node named \(target.node)",
                    subtitle: "Check the palette's file",
                    isEnabled: false,
                    action: {}
                ),
            ])]
        }
        let search = SearchQuery(query.trimmed)
        let written: [PaletteItem] = node.items.enumerated().compactMap { index, entry in
            guard let match = Search.match(search, fields: [entry.title, entry.subtitle].compactMap(\.self)) else { return nil }
            // Every value in a written item is literal, so a `copy:` or
            // `open:` operand is the action's own text.
            return item(Row(
                id: "menu:\(index)",
                title: entry.title,
                subtitle: entry.subtitle,
                icon: entry.icon ?? node.icon,
                exports: entry.exports,
                outcome: entry.outcome,
                operand: entry.outcome.literalOperand,
                alt: entry.alt,
                altOperand: entry.alt.flatMap { CustomPaletteOutcome.perform($0.action).literalOperand }
            ), context: context).with(match)
        }
        let listed: [PaletteItem] = node.listing.map { listing in
            (rows ?? []).enumerated().compactMap { index, row in
                guard let match = Search.match(search, fields: row.match) else { return nil }
                return item(Row(
                    id: "row:\(index)",
                    title: row.title,
                    subtitle: row.subtitle,
                    icon: row.icon ?? node.icon,
                    exports: row.exports,
                    outcome: listing.outcome,
                    operand: row.operand,
                    alt: listing.alt,
                    altOperand: row.altOperand
                ), context: context).with(match)
            }
        } ?? []
        let items = written + listed
        // Empty, the listing's own order; searching, best match first with
        // that order breaking ties.
        let ranked = query.isEmpty ? items : items.enumerated()
            .sorted { ($0.element.score, $0.offset) < ($1.element.score, $1.offset) }
            .map(\.element)
        return ranked.isEmpty ? [] : [PaletteSection(header: nil, items: ranked)]
    }

    /// What a menu item and a listing row have in common once resolved:
    /// everything a palette row is built from.
    private struct Row {
        let id: String
        let title: String
        let subtitle: String?
        let icon: String?
        let exports: [String: String]
        let outcome: CustomPaletteOutcome
        let operand: String?
        let alt: CustomPaletteAlt?
        let altOperand: String?
    }

    private func item(_ row: Row, context: PaletteContext) -> PaletteItem {
        let exports = target.exports.merging(row.exports) { _, new in new }
        let alt = row.alt.map { alt in
            PaletteAltAction(title: alt.title) { [
                appState = context.appState,
                projects = context.projectStore.projects,
                altOperand = row.altOperand
            ] in
                CustomPaletteActions.perform(alt.action, operand: altOperand, exports: exports, appState: appState, projects: projects)
            }
        }
        switch row.outcome {
        case let .enter(node):
            let nextIcon = palette(context)?.nodes[node]?.icon ?? row.icon ?? target.pill.systemImage
            let next = target.entering(node, pill: PalettePill(title: row.title, systemImage: nextIcon), adding: row.exports)
            return PaletteItem(
                id: "\(target.node)/\(row.id)",
                title: row.title,
                subtitle: row.subtitle,
                opensScope: .custom(next),
                icon: row.icon,
                alt: alt,
                action: {}
            )
        case let .perform(action):
            let operand = row.operand
            return PaletteItem(
                id: "\(target.node)/\(row.id)",
                title: row.title,
                subtitle: row.subtitle,
                icon: row.icon,
                alt: alt,
                action: { [appState = context.appState, projects = context.projectStore.projects] in
                    CustomPaletteActions.perform(action, operand: operand, exports: exports, appState: appState, projects: projects)
                }
            )
        }
    }

    // MARK: - Context

    static func projectDirectory(_ context: PaletteContext) -> String? {
        guard let projectID = context.appState.activeProjectID,
              let project = context.projectStore.projects.first(where: { $0.id == projectID }),
              !project.isRemote
        else { return nil }
        return project.path
    }

    static func environment(for target: CustomPaletteTarget, context: PaletteContext) -> [String: String] {
        let project = context.appState.activeProjectID.flatMap { id in context.projectStore.projects.first { $0.id == id } }
        return CustomPaletteEnvironment.make(
            projectName: project?.name,
            projectDirectory: projectDirectory(context),
            exports: target.exports
        )
    }
}

private extension CustomPaletteOutcome {
    /// A written item's `copy:` or `open:` text, which is literal.
    var literalOperand: String? {
        switch self {
        case let .perform(.copy(text)),
             let .perform(.open(text)): text
        case .perform(.run),
             .enter: nil
        }
    }
}

/// What a custom palette's row does when picked, after the palette closes.
@MainActor
enum CustomPaletteActions {
    static func perform(
        _ action: CustomPaletteAction,
        operand: String?,
        exports: [String: String],
        appState: AppState,
        projects: [Project]
    ) {
        switch action {
        case let .run(command, place):
            guard let projectID = appState.activeProjectID,
                  let project = projects.first(where: { $0.id == projectID })
            else {
                appState.presentToast("No project to run in")
                return
            }
            var env = CustomPaletteEnvironment.make(
                projectName: project.name,
                projectDirectory: project.isRemote ? nil : project.path,
                exports: exports
            )
            // A local pane runs it before its shell, untyped
            // (`CustomPaletteLaunch`). A remote pane is ssh, whose environment
            // stays on this Mac, so there it is typed for the host's shell.
            let typed: String? = project.isRemote ? command : nil
            if !project.isRemote { env[CustomPaletteScript.commandVariable] = CustomPaletteScript.script(command) }
            switch place {
            case .tab:
                appState.createTab(projectID: projectID, projects: projects, command: typed, env: env)
            case .split:
                if let pane = appState.focusedPane(for: projectID) {
                    appState.splitPane(
                        pane.id,
                        direction: .auto(for: pane.nsView?.bounds.size ?? .zero),
                        projectID: projectID,
                        projectDirectory: project.path,
                        command: typed,
                        env: env
                    )
                } else {
                    appState.createTab(projectID: projectID, projects: projects, command: typed, env: env)
                }
            }
        case .copy:
            guard let operand else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(operand, forType: .string)
        case .open:
            guard let operand else { return }
            if let url = URL(string: operand), url.scheme != nil {
                NSWorkspace.shared.open(url)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: (operand as NSString).expandingTildeInPath))
            }
        }
    }
}
