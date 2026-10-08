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
/// `sh -o errexit` or its `#!` interpreter (`CustomPaletteScript`) with the
/// target's exports in the environment, reports `loading` meanwhile, keeps
/// the rows and filters them per
/// keystroke. A command that fails — not found, non-zero, output that isn't
/// the shape asked for — becomes `failure`, retried with ⌘R.
@MainActor
final class CustomPaletteScope: PaletteScope {
    let target: CustomPaletteTarget
    private let runner: CustomPaletteCommandRunner
    private let conditionRunner: CustomPaletteCommandRunner

    private(set) var loading: PaletteLoading?
    private(set) var failure: PaletteFailure?
    private var rows: [CustomPaletteRow]? {
        didSet { rowSearch = rows.map { SearchSession(index: SearchIndex($0.map(\.match))) } }
    }

    /// The listing's rows prepared for search once, when they arrive: a
    /// listing can be thousands of lines, and each keystroke then only
    /// searches — only the last matches, when it narrows the query.
    private var rowSearch: SearchSession?
    private var task: Task<Void, Never>?
    private var onChange: (@MainActor () -> Void)?
    private var context: PaletteContext?

    /// The `when:` checks running (`CustomPaletteCondition`): the palette's
    /// own on its root, then its items'.
    private var checks: Task<Void, Never>?
    /// While the palette's own check runs on its root, nothing is shown: a
    /// palette that can't be used now says why rather than listing.
    private var gated = false
    /// The items' checks, by command — each run once per screen, however
    /// many items share it.
    private var itemVerdicts: [String: Bool] = [:]
    /// Whether this screen has started its checks and listing: once per
    /// frame, so returning to it restarts nothing; ⌘R starts them again.
    private var begun = false

    init(
        target: CustomPaletteTarget,
        runner: @escaping CustomPaletteCommandRunner = CustomPaletteRunner.run,
        conditionRunner: @escaping CustomPaletteCommandRunner = CustomPaletteRunner.checkCondition
    ) {
        self.target = target
        self.runner = runner
        self.conditionRunner = conditionRunner
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
        guard fileReads(context), !begun else { return }
        begun = true
        begin()
    }

    /// On the palette's root, its own `when:` first; then the items' checks
    /// and the listing, side by side.
    private func begin() {
        guard let context, let palette = palette(context) else { return }
        guard target.node == palette.root, let condition = palette.condition else { return proceed() }
        let (environment, cwd) = Self.commandContext(for: target, context: context)
        let runner = conditionRunner
        gated = true
        loading = PaletteLoading(message: "Checking \(palette.name)…")
        onChange?()
        checks = Task { @MainActor [weak self] in
            let verdicts = await CustomPaletteConditions.evaluate(
                [condition.command], environment: environment, currentDirectory: cwd, runner: runner
            )
            guard let self, !Task.isCancelled else { return }
            checks = nil
            loading = nil
            gated = false
            if verdicts[condition.command] == true {
                proceed()
            } else {
                failure = PaletteFailure(title: "\(palette.name) isn't available", detail: condition.reason)
                onChange?()
            }
        }
    }

    private func proceed() {
        startItemChecks()
        if let context, node(context)?.listing != nil {
            startListing()
        } else {
            onChange?()
        }
    }

    /// The items' `when:` checks, each distinct command once. An item is
    /// usable until its check says otherwise.
    private func startItemChecks() {
        guard let context, let node = node(context) else { return }
        let commands = Set(node.items.compactMap(\.condition?.command))
        guard !commands.isEmpty else { return }
        let (environment, cwd) = Self.commandContext(for: target, context: context)
        let runner = conditionRunner
        checks = Task { @MainActor [weak self] in
            let verdicts = await CustomPaletteConditions.evaluate(
                commands, environment: environment, currentDirectory: cwd, runner: runner
            )
            guard let self, !Task.isCancelled else { return }
            checks = nil
            itemVerdicts = verdicts
            onChange?()
        }
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
        checks?.cancel()
        checks = nil
    }

    func retry() {
        guard task == nil, checks == nil else { return }
        failure = nil
        itemVerdicts = [:]
        // The file may have been fixed since: read it again before deciding
        // what there is to check and list.
        guard let context else { return }
        context.appState.customPalettes.reload()
        guard fileReads(context) else {
            onChange?()
            return
        }
        begun = true
        begin()
    }

    private func startListing() {
        guard let context, let palette = palette(context), let listing = palette.nodes[target.node]?.listing else { return }
        let (environment, cwd) = Self.commandContext(for: target, context: context)
        let invocation = CustomPaletteScript.invocation(of: listing.command)
        let requires = palette.requires
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
        guard fileReads(context), !gated, let palette = palette(context) else { return [] }
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
                altOperand: entry.alt.flatMap { CustomPaletteOutcome.perform($0.action).literalOperand },
                unavailable: entry.condition.flatMap { itemVerdicts[$0.command] == false ? $0.reason : nil }
            ), context: context).with(match)
        }
        let listed: [PaletteItem] = node.listing.map { listing in
            guard let rows, let rowSearch else { return [] }
            let found: [(index: Int, score: Int32)] = search.isEmpty
                ? rows.indices.map { ($0, 0) }
                : rowSearch.search(query.trimmed).map { ($0.index, $0.score) }
            return found.map { index, score in
                let row = rows[index]
                // Highlights are offsets in the first field matched, which
                // is the title unless the row's `match:` leads with another.
                let highlights = !search.isEmpty && row.match.first == row.title
                    ? rowSearch.index.highlights(search, at: index) : []
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
                ), context: context).with(score: -Int(score), highlights: highlights)
            }
        } ?? []
        let items = written + listed
        // Empty, the listing's own order; searching, best match first.
        let ranked = query.isEmpty ? items : items.rankedByScore()
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
        /// Why the row can't be used now (its `when:` failed): muted, with
        /// this in place of its subtitle.
        var unavailable: String?
    }

    private func item(_ row: Row, context: PaletteContext) -> PaletteItem {
        let subtitle = row.unavailable ?? row.subtitle
        let isEnabled = row.unavailable == nil
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
                subtitle: subtitle,
                isEnabled: isEnabled,
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
                subtitle: subtitle,
                isEnabled: isEnabled,
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

    /// Where a listing or a check runs: the target's environment, in the
    /// project's directory — a remote project's or the pinned tabs' on this
    /// Mac, in the home folder rather than the app's own `/`.
    static func commandContext(for target: CustomPaletteTarget, context: PaletteContext) -> ([String: String], String) {
        commandContext(exports: target.exports, context: context)
    }

    static func commandContext(exports: [String: String], context: PaletteContext) -> ([String: String], String) {
        (
            environment(exports: exports, context: context),
            projectDirectory(context) ?? FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    static func environment(for target: CustomPaletteTarget, context: PaletteContext) -> [String: String] {
        environment(exports: target.exports, context: context)
    }

    static func environment(exports: [String: String], context: PaletteContext) -> [String: String] {
        let project = context.appState.activeProjectID.flatMap { id in context.projectStore.projects.first { $0.id == id } }
        return CustomPaletteEnvironment.make(
            projectName: project?.name,
            projectDirectory: projectDirectory(context),
            exports: exports
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
            guard let projectID = appState.activeProjectID else {
                appState.presentToast("No project to run in")
                return
            }
            // A pinned tab belongs to no project. A tab born in the pinned
            // workspace would be pinned itself, so the command always splits
            // beside the focused pane there, as a clicked text file does.
            if projectID == PinnedTabs.projectID {
                guard let pane = appState.focusedPane(for: projectID) else {
                    appState.presentToast("No pane to run beside")
                    return
                }
                var env = CustomPaletteEnvironment.make(projectName: nil, projectDirectory: nil, exports: exports)
                env[CustomPaletteScript.commandVariable] = CustomPaletteScript.script(command)
                appState.splitPane(
                    pane.id,
                    direction: .auto(for: pane.nsView?.bounds.size ?? .zero),
                    projectID: projectID,
                    projectDirectory: PinnedTabs.fallbackRoot,
                    command: nil,
                    env: env
                )
                return
            }
            guard let project = projects.first(where: { $0.id == projectID }) else {
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
                NSWorkspace.shared.open(fileURL(operand, appState: appState, projects: projects))
            }
        }
    }

    /// An `open:` path as a file URL: a relative one (`git ls-files`'s
    /// `src/main.swift`) against the active local project, where the
    /// listing that printed it ran, else the home folder — never the app's
    /// own `/`.
    static func fileURL(_ operand: String, appState: AppState, projects: [Project]) -> URL {
        let path = (operand as NSString).expandingTildeInPath
        guard !path.hasPrefix("/") else { return URL(fileURLWithPath: path) }
        let project = appState.activeProjectID.flatMap { id in projects.first { $0.id == id } }
        let base = project.flatMap { $0.isRemote ? nil : $0.path } ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(path).standardizedFileURL
    }
}
