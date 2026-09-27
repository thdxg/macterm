import AppKit
import os

private let logger = Logger(subsystem: appBundleID, category: "AppState+DesktopWidgets")

/// The windows that draw `AppState.desktopWidgets` on the desktop
/// (`DesktopWidgetWindows`). A protocol so the model stays testable without
/// opening windows: tests leave the presenter nil or record the calls.
@MainActor
protocol DesktopWidgetPresenting: AnyObject {
    /// Bring the widget windows in line with `widgets` and the one being
    /// edited — open the missing, close the removed, and restyle or reframe
    /// the rest. Idempotent.
    func sync(_ widgets: [DesktopWidget], editing: UUID?)
}

/// Desktop widgets: terminals on the desktop, each one pane whose session
/// persists the way a pinned tab's does — in the same two layers.
///
/// - The snapshot (`WorkspacesFile.desktopWidgets`) carries each widget's
///   session identity, so a relaunch reattaches its shell; the orphan reaper
///   counts those sessions as claimed.
/// - `widgets.yaml` (`WidgetLayoutStore`) is the declaration: which widgets
///   exist, their size and grid cell, and the recipe (`cwd`, `run`) a widget
///   respawns from when its session is gone. It is authoritative for
///   membership at launch, and Macterm rewrites it after every change —
///   absorbing whatever the user edited since its last write first.
///
/// A widget is locked — no input reaches it at all — unless it is the one
/// being edited. Editing is one widget at a time and never persisted.
///
/// Widget panes live outside every workspace, like the quick terminal's, so
/// the workspace machinery (leadership, mirrors, the poll) never sees them.
/// A widget's session is never shared, which is why removal kills it
/// directly rather than through `releaseSessions`.
extension AppState {
    /// Point the model at the windows that draw it, and draw what exists.
    func attachDesktopWidgetPresenter(_ presenter: any DesktopWidgetPresenting) {
        desktopWidgetPresenter = presenter
        syncDesktopWidgetPresenter()
    }

    func desktopWidget(id: UUID) -> DesktopWidget? {
        desktopWidgets.first { $0.id == id }
    }

    func desktopVisibleFrames() -> [CGRect] {
        desktopScreens().map(\.visibleFrame)
    }

    /// Put a new, locked widget running a fresh shell (and `command`, if
    /// any) in the free grid cell nearest the middle of the primary display.
    /// `span` defaults to Settings → Widgets' default size.
    @discardableResult
    func createDesktopWidget(span: DesktopWidgetSpan? = nil, name: String? = nil, command: String? = nil) -> DesktopWidget {
        let widget = makeDesktopWidget(span: span, name: name, command: command, cwd: nil)
        desktopWidgets.append(widget)
        logger.info("created desktop widget \(widget.id.uuidString, privacy: .public) (\(widget.span.description, privacy: .public))")
        desktopWidgetsDidChange()
        return widget
    }

    private func makeDesktopWidget(span: DesktopWidgetSpan?, name: String?, command: String?, cwd: String?) -> DesktopWidget {
        let span = span ?? Preferences.shared.desktopWidgetDefaultSize.span
        let occupied = desktopWidgets.map(\.frame) + nativeDesktopWidgetFrames()
        let topLeft = desktopVisibleFrames().first.map {
            DesktopWidgetGrid.centered(span, in: $0, avoiding: occupied)
        } ?? .zero
        return DesktopWidget(name: name, span: span, topLeft: topLeft, command: command, cwd: cwd)
    }

    /// Remove a widget for good: its shell ends and its session is killed.
    /// Unconditional — the confirmation for a busy pane belongs to the
    /// caller (`desktopWidgetNeedsConfirmRemove`), as with every close verb.
    func removeDesktopWidget(id: UUID) {
        guard let index = desktopWidgets.firstIndex(where: { $0.id == id }) else { return }
        let widget = desktopWidgets.remove(at: index)
        if editingDesktopWidgetID == id { editingDesktopWidgetID = nil }
        endSessions(of: widget)
        logger.info("removed desktop widget \(id.uuidString, privacy: .public)")
        desktopWidgetsDidChange()
    }

    private func endSessions(of widget: DesktopWidget) {
        for pane in widget.tab.splitRoot.allPanes() {
            pane.destroySurface()
            pane.killPersistentSession(using: zmx)
        }
    }

    /// Whether removing the widget would end a running program.
    func desktopWidgetNeedsConfirmRemove(id: UUID) -> Bool {
        guard let pane = desktopWidget(id: id)?.pane else { return false }
        // Widget panes are outside the poll, so their sample is read fresh.
        pane.refreshForegroundProcess(trackExecution: false)
        return pane.needsConfirmClose
    }

    // MARK: - Editing

    /// Whether `id` may start editing: nothing else is being edited.
    func canEditDesktopWidget(id: UUID) -> Bool {
        editingDesktopWidgetID == nil || editingDesktopWidgetID == id
    }

    /// Unlock a widget: its terminal takes input and it can be moved and
    /// resized. Refused (false) while another widget is being edited — the
    /// user locks that one first.
    @discardableResult
    func beginEditingDesktopWidget(id: UUID) -> Bool {
        guard desktopWidget(id: id) != nil, canEditDesktopWidget(id: id) else { return false }
        guard editingDesktopWidgetID != id else { return true }
        editingDesktopWidgetID = id
        syncDesktopWidgetPresenter()
        return true
    }

    /// Lock whichever widget is being edited. The user has typed into it, so
    /// this is also when its recipe (what it runs, where) is worth
    /// re-capturing.
    func endEditingDesktopWidget() {
        guard editingDesktopWidgetID != nil else { return }
        editingDesktopWidgetID = nil
        desktopWidgetsDidChange()
    }

    // MARK: - Geometry

    /// Pick a size, keeping the top-left corner where it is — unless the
    /// grid moves the widget to stay on screen and off its neighbours.
    func setDesktopWidgetSpan(_ span: DesktopWidgetSpan, id: UUID) {
        guard let widget = desktopWidget(id: id), widget.span != span else { return }
        settleDesktopWidget(id: id, frame: DesktopWidgetGrid.frame(topLeft: widget.topLeft, span: span))
    }

    /// The user let go of a widget they dragged or resized to `frame`: snap
    /// it to the nearest free cell and span of the lattice it belongs to —
    /// that of a widget near it, the system's own included, else the
    /// screen's default one — and persist that.
    func settleDesktopWidget(id: UUID, frame: CGRect) {
        guard let widget = desktopWidget(id: id) else { return }
        if let screen = DesktopWidgetGrid.screen(for: frame, among: desktopVisibleFrames()) {
            let others = desktopWidgets.filter { $0.id != id }.map(\.frame) + nativeDesktopWidgetFrames()
            let snapped = DesktopWidgetGrid.snap(frame, in: screen, avoiding: others)
            widget.topLeft = snapped.topLeft
            widget.span = snapped.span
        } else {
            widget.topLeft = CGPoint(x: frame.minX, y: frame.maxY)
        }
        desktopWidgetsDidChange()
    }

    /// Snap every widget onto its screen's grid in order, each clear of the
    /// ones before it — after a declaration moved several at once.
    private func tidyDesktopWidgets() {
        let frames = desktopVisibleFrames()
        var placed = nativeDesktopWidgetFrames()
        for widget in desktopWidgets {
            if let screen = DesktopWidgetGrid.screen(for: widget.frame, among: frames) {
                let snapped = DesktopWidgetGrid.snap(widget.frame, in: screen, avoiding: placed)
                widget.topLeft = snapped.topLeft
                widget.span = snapped.span
            }
            placed.append(widget.frame)
        }
    }

    /// The widget's shell exited (`exit`, or its session was killed from
    /// outside). A widget always holds a terminal — that is what the user
    /// placed on the desktop — so it starts over in a fresh session rather
    /// than closing.
    func desktopWidgetShellExited(id: UUID) {
        guard let widget = desktopWidget(id: id) else { return }
        endSessions(of: widget)
        widget.startOver()
        logger.info("desktop widget \(id.uuidString, privacy: .public) shell exited; started over")
        desktopWidgetsDidChange()
    }

    // MARK: - Snapshot

    /// Hand the persisted widgets back, all locked, and return the ids
    /// restored — `materializeRestoredDesktopWidgets` checks their sessions
    /// before they are drawn. A widget whose saved spot is no longer on any
    /// screen (its display went away) is placed afresh; a widget already
    /// live under the same id is left alone.
    @discardableResult
    func restoreDesktopWidgets(_ snapshots: [DesktopWidgetSnapshot]) -> Set<UUID> {
        let frames = desktopVisibleFrames()
        var restored: Set<UUID> = []
        for snapshot in snapshots where desktopWidget(id: snapshot.id) == nil {
            let widget = DesktopWidget(
                id: snapshot.id,
                tab: WorkspaceSerializer.restoreTab(snapshot.tab, projectID: DesktopWidget.projectID),
                name: snapshot.name,
                span: DesktopWidgetSpan(columns: snapshot.columns, rows: snapshot.rows),
                topLeft: CGPoint(x: snapshot.topLeftX, y: snapshot.topLeftY),
                command: snapshot.command,
                cwd: snapshot.cwd
            )
            if let screen = frames.first, !DesktopWidgetGrid.isReachable(widget.frame, on: frames) {
                let occupied = desktopWidgets.map(\.frame) + nativeDesktopWidgetFrames()
                widget.topLeft = DesktopWidgetGrid.centered(widget.span, in: screen, avoiding: occupied)
            }
            desktopWidgets.append(widget)
            restored.insert(widget.id)
        }
        pendingDesktopWidgetMaterialize.formUnion(restored)
        return restored
    }

    /// Ask zmx which restored widgets' sessions survived the quit, respawn
    /// the rest from their recipe, and only then draw them — the pinned
    /// tabs' rule, for the same reason: a surface attaching first would get
    /// zmx's fresh empty shell (attach is an upsert) and never run the
    /// widget's command. A failed listing reattaches everything: fail toward
    /// reattach, never toward respawning over sessions that may be alive.
    func materializeRestoredDesktopWidgets(_ ids: Set<UUID>) async {
        guard !ids.isEmpty else { return }
        var alive: Set<String>? = if zmx.isBundled() {
            await zmx.listSessionsWithClients().map { Set($0.map(\.name)) }
        } else {
            []
        }
        var respawned = false
        if let alive {
            for widget in desktopWidgets where ids.contains(widget.id) {
                guard let pane = widget.pane, !alive.contains(pane.sessionName), pane.nsView == nil else { continue }
                logger.info("desktop widget \(widget.id.uuidString, privacy: .public): session gone; respawning")
                widget.startOver()
                respawned = true
            }
        }
        pendingDesktopWidgetMaterialize.subtract(ids)
        if respawned { saveDesktopWidgetsIfRestored() }
        syncDesktopWidgetPresenter()
    }

    func desktopWidgetSnapshots() -> [DesktopWidgetSnapshot] {
        desktopWidgets.map { widget in
            DesktopWidgetSnapshot(
                id: widget.id,
                name: widget.name,
                tab: WorkspaceSerializer.snapshotTab(widget.tab),
                columns: widget.span.columns,
                rows: widget.span.rows,
                topLeftX: widget.topLeft.x,
                topLeftY: widget.topLeft.y,
                command: widget.command,
                cwd: widget.cwd
            )
        }
    }

    /// The sessions widget panes hold — claims for the orphan reaper, since a
    /// restored widget attaches only once its window has a surface.
    func desktopWidgetSessionNames() -> Set<String> {
        Set(desktopWidgets.flatMap { $0.tab.splitRoot.allPanes().map(\.sessionName) })
    }

    // MARK: - widgets.yaml

    /// Re-capture each live widget's recipe from what its pane is running —
    /// the pinned tabs' capture (`LayoutSerializer.pinnedDeclaration`), and
    /// their rule that an idle capture never ERASES an established `run:`:
    /// a pane at its prompt says nothing about what it should respawn with.
    func refreshDesktopWidgetRecipes() {
        for widget in desktopWidgets where widget.pane?.nsView != nil {
            guard case let .pane(leaf) = LayoutSerializer.pinnedDeclaration(for: widget.tab).layout else { continue }
            if let cwd = leaf.cwd { widget.cwd = cwd }
            if let run = leaf.run { widget.command = run }
        }
    }

    /// A widget as `widgets.yaml` declares it: its grid cell on its screen
    /// (named only when it isn't the primary display).
    func desktopWidgetDeclaration(_ widget: DesktopWidget) -> WidgetDeclaration {
        let screens = desktopScreens()
        let frames = screens.map(\.visibleFrame)
        var column: Int?
        var row: Int?
        var display: String?
        if let frame = DesktopWidgetGrid.screen(for: widget.frame, among: frames),
           let index = frames.firstIndex(of: frame)
        {
            let origin = DesktopWidgetGrid.origin(in: frame)
            column = Int(((widget.topLeft.x - origin.x) / DesktopWidgetGrid.pitch).rounded())
            row = Int(((origin.y - widget.topLeft.y) / DesktopWidgetGrid.pitch).rounded())
            display = index == 0 ? nil : screens[index].name
        }
        return WidgetDeclaration(
            name: widget.name,
            size: DesktopWidgetSize.name(of: widget.span),
            column: column,
            row: row,
            display: display,
            cwd: widget.cwd,
            run: widget.command
        )
    }

    /// Make `widget` what `entry` declares. The recipe applies to the next
    /// fresh session; size and place apply now.
    private func adopt(_ entry: WidgetDeclaration, into widget: DesktopWidget) {
        widget.name = entry.name
        widget.command = entry.run
        widget.cwd = entry.cwd
        widget.span = entry.size.flatMap(DesktopWidgetSize.parseSpan) ?? Preferences.shared.desktopWidgetDefaultSize.span
        let screens = desktopScreens()
        if let column = entry.column, let row = entry.row,
           let screen = screens.first(where: { $0.name == entry.display }) ?? screens.first
        {
            widget.topLeft = DesktopWidgetGrid.topLeft(column: max(0, column), row: max(0, row), in: screen.visibleFrame)
        }
    }

    /// A widget for an entry the user added by hand: a fresh session running
    /// its recipe, in its declared cell (else the middle of the screen).
    private func makeDeclaredWidget(_ entry: WidgetDeclaration) -> DesktopWidget {
        let widget = makeDesktopWidget(
            span: entry.size.flatMap(DesktopWidgetSize.parseSpan),
            name: entry.name,
            command: entry.run,
            cwd: entry.cwd
        )
        adopt(entry, into: widget)
        return widget
    }

    /// Launch reconcile: `widgets.yaml` is authoritative for membership.
    /// Matched entries update their widget (keeping its session), unmatched
    /// ones become new widgets, and widgets the file no longer lists are
    /// removed. An absent file is "no input" (a first launch, an editor's
    /// truncate-then-write) and is written from the snapshot; an unparseable
    /// one suspends auto-writes and changes nothing.
    func reconcileWidgetLayoutAtLaunch() {
        switch widgetLayoutStore.read() {
        case .absent:
            if !desktopWidgets.isEmpty { writeWidgetLayout() }
        case let .invalid(reason):
            suspendWidgetLayoutWrites(reason: reason)
        case let .file(entries, text):
            let matching = WidgetLayoutMatcher.match(entries: entries, current: desktopWidgets.map(desktopWidgetDeclaration))
            let current = desktopWidgets
            var result: [DesktopWidget] = []
            for (entry, index) in matching.pairs {
                if let index {
                    adopt(entry, into: current[index])
                    result.append(current[index])
                } else {
                    let widget = makeDeclaredWidget(entry)
                    logger.info("widgets.yaml added a widget; created \(widget.id.uuidString, privacy: .public)")
                    desktopWidgets.append(widget)
                    result.append(widget)
                }
            }
            for index in matching.removed {
                logger.info("widgets.yaml removed desktop widget \(current[index].id.uuidString, privacy: .public)")
                endSessions(of: current[index])
                pendingDesktopWidgetMaterialize.remove(current[index].id)
            }
            desktopWidgets = result
            tidyDesktopWidgets()
            widgetLayoutLastWrittenText = text
            widgetLayoutSuspended = false
            saveWorkspaces()
            syncDesktopWidgetPresenter()
        }
    }

    /// Rewrite `widgets.yaml` from the widgets — after absorbing any edit made
    /// since our last write (tracked by exact text). Additions become widgets
    /// and edits apply now; removing a widget that is running is honored at
    /// launch only, so an editor's half-saved file can never kill a shell. A
    /// file that doesn't parse suspends auto-writes rather than clobbering
    /// the user's work. Nothing is ever created for someone who has never had
    /// a widget.
    func writeWidgetLayout() {
        let onDisk = widgetLayoutStore.read()
        if widgetLayoutSuspended {
            if case .invalid = onDisk { return }
            widgetLayoutSuspended = false
        }
        switch onDisk {
        case .absent:
            guard !(desktopWidgets.isEmpty && widgetLayoutLastWrittenText == nil) else { return }
        case let .invalid(reason):
            suspendWidgetLayoutWrites(reason: reason)
            return
        case let .file(entries, text):
            if text != widgetLayoutLastWrittenText { absorbExternalWidgetEdits(entries) }
        }
        do {
            widgetLayoutLastWrittenText = try widgetLayoutStore.write(widgets: desktopWidgets.map(desktopWidgetDeclaration))
        } catch {
            logger.error("Failed to write widgets.yaml: \(error, privacy: .public)")
        }
    }

    private func absorbExternalWidgetEdits(_ entries: [WidgetDeclaration]) {
        logger.info("widgets.yaml changed externally; absorbing before write")
        let matching = WidgetLayoutMatcher.match(entries: entries, current: desktopWidgets.map(desktopWidgetDeclaration))
        let current = desktopWidgets
        var result: [DesktopWidget] = matching.pairs.map { entry, index in
            if let index {
                adopt(entry, into: current[index])
                return current[index]
            }
            return makeDeclaredWidget(entry)
        }
        result += matching.removed.map { current[$0] }
        desktopWidgets = result
        tidyDesktopWidgets()
        saveWorkspaces()
        syncDesktopWidgetPresenter()
    }

    private func suspendWidgetLayoutWrites(reason: String) {
        guard !widgetLayoutSuspended else { return }
        widgetLayoutSuspended = true
        logger.error("widgets.yaml auto-save suspended: \(reason, privacy: .public)")
        presentLayoutError(
            verb: "save",
            message: "\(reason)\n\nWidget auto-save is paused so your edits aren’t overwritten. "
                + "Fix the file (or delete it) to resume.",
            title: "Widget layout file problem"
        )
    }

    // MARK: - Plumbing

    private func syncDesktopWidgetPresenter() {
        let shown = desktopWidgets.filter { !pendingDesktopWidgetMaterialize.contains($0.id) }
        desktopWidgetPresenter?.sync(shown, editing: editingDesktopWidgetID)
    }

    private func desktopWidgetsDidChange() {
        saveDesktopWidgetsIfRestored()
        syncDesktopWidgetPresenter()
    }

    /// Both layers, gated on the launch restore like the quick terminal's
    /// saves: until it has run, `workspaces` is empty and a save would write
    /// that emptiness over the file about to be restored.
    private func saveDesktopWidgetsIfRestored() {
        guard hasRestoredSelection else { return }
        refreshDesktopWidgetRecipes()
        saveWorkspaces()
        writeWidgetLayout()
    }
}
