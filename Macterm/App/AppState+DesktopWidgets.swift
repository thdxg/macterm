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
    /// any) in the middle of the primary display (`DesktopWidgetGrid.centered`).
    /// `span` defaults to `DesktopWidgetSpan.initial`.
    @discardableResult
    func createDesktopWidget(span: DesktopWidgetSpan? = nil, name: String? = nil, command: String? = nil) -> DesktopWidget {
        let widget = makeDesktopWidget(span: span, name: name, command: command, cwd: nil)
        desktopWidgets.append(widget)
        logger.info("created desktop widget \(widget.id.uuidString, privacy: .public) (\(widget.span.description, privacy: .public))")
        desktopWidgetsDidChange()
        return widget
    }

    private func makeDesktopWidget(span: DesktopWidgetSpan?, name: String?, command: String?, cwd: String?) -> DesktopWidget {
        let span = span ?? .initial
        let occupied = desktopWidgets.map(\.frame) + nativeDesktopWidgetFrames()
        let topLeft = desktopVisibleFrames().first.map {
            DesktopWidgetGrid.centered(span, in: $0, avoiding: occupied)
        } ?? .zero
        let widget = DesktopWidget(name: name, span: span, topLeft: topLeft, command: command, cwd: cwd)
        recordPlacement(of: widget)
        return widget
    }

    /// Remove a widget for good: its shell ends and its session is killed.
    /// Unconditional — the confirmation for a busy pane belongs to the
    /// caller (`desktopWidgetNeedsConfirmRemove`), as with every close verb.
    func removeDesktopWidget(id: UUID) {
        guard let index = desktopWidgets.firstIndex(where: { $0.id == id }) else { return }
        let widget = desktopWidgets.remove(at: index)
        if editingDesktopWidgetID == id { editingDesktopWidgetID = nil }
        unlistedDesktopWidgetIDs.remove(id)
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
            recordPlacement(of: widget)
        } else {
            widget.topLeft = CGPoint(x: frame.minX, y: frame.maxY)
        }
        desktopWidgetsDidChange()
    }

    /// Snap the widgets in `ids` onto their screens' grids, each clear of
    /// every other widget — after a declaration placed them. Only those: a
    /// widget the file left alone stays exactly where it settled.
    private func tidyDesktopWidgets(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let frames = desktopVisibleFrames()
        var placed = nativeDesktopWidgetFrames() + desktopWidgets.filter { !ids.contains($0.id) }.map(\.frame)
        for widget in desktopWidgets where ids.contains(widget.id) {
            if let screen = DesktopWidgetGrid.screen(for: widget.frame, among: frames) {
                let snapped = DesktopWidgetGrid.snap(widget.frame, in: screen, avoiding: placed)
                widget.topLeft = snapped.topLeft
                widget.span = snapped.span
                recordPlacement(of: widget)
            }
            placed.append(widget.frame)
        }
    }

    // MARK: - Displays

    /// Remember where `widget` is now as where the user put it on the screen
    /// it is on (`DesktopWidgetPlacement`). Only what the user did is
    /// recorded — creating, moving, resizing, declaring — never a projection
    /// onto another display.
    private func recordPlacement(of widget: DesktopWidget) {
        let screens = desktopScreens()
        guard let visible = DesktopWidgetGrid.screen(for: widget.frame, among: screens.map(\.visibleFrame)),
              let screen = screens.first(where: { $0.visibleFrame == visible })
        else { return }
        widget.placements = DesktopWidgetPlacement.recording(
            DesktopWidgetPlacement(topLeft: widget.topLeft, on: screen),
            into: widget.placements
        )
    }

    /// The displays changed — one was connected or disconnected, or a
    /// resolution changed. Put every widget where the user put it on the
    /// display it now belongs to, or project its latest placement there, the
    /// way Notification Center moves the system's widgets
    /// (`DesktopWidgetPlacement`). `DesktopWidgetWindows` calls this once the
    /// reconfiguration has settled.
    func desktopScreensDidChange() {
        guard hasRestoredSelection, !desktopWidgets.isEmpty else { return }
        let before = desktopWidgets.map(\.topLeft)
        placeForCurrentScreens(desktopWidgets, avoiding: nativeDesktopWidgetFrames())
        guard desktopWidgets.map(\.topLeft) != before else { return }
        logger.info("displays changed; moved desktop widgets to match")
        desktopWidgetsDidChange()
    }

    /// Place `widgets` on the screens as they are now. The ones with a
    /// placement for their display at this resolution go first and exactly
    /// there; projections go after, and one that would land on another widget
    /// (the offsets came from a bigger screen, or were pushed in from its
    /// edge) moves to the nearest free cell. The span is never changed —
    /// shrinking a widget to fit a small display would lose its size for the
    /// big one. A widget with no placement at all (a snapshot from before
    /// placements, off every screen) goes in the middle of the primary display.
    private func placeForCurrentScreens(_ widgets: [DesktopWidget], avoiding others: [CGRect]) {
        let screens = desktopScreens()
        guard let primary = screens.first else { return }
        let ids = Set(widgets.map(\.id))
        var placed = others + desktopWidgets.filter { !ids.contains($0.id) }.map(\.frame)
        let targets = widgets.map { widget in
            (widget, DesktopWidgetPlacement.resolve(widget.placements, size: widget.frame.size, on: screens))
        }
        let ordered = targets.filter { $0.1?.exact == true } + targets.filter { $0.1?.exact != true }
        for (widget, target) in ordered {
            guard let target else {
                widget.topLeft = DesktopWidgetGrid.centered(widget.span, in: primary.visibleFrame, avoiding: placed)
                recordPlacement(of: widget)
                placed.append(widget.frame)
                continue
            }
            widget.topLeft = target.topLeft
            if placed.contains(where: { $0.insetBy(dx: 1, dy: 1).intersects(widget.frame) }) {
                widget.topLeft = DesktopWidgetGrid.snap(widget.frame, in: target.screen.visibleFrame, avoiding: placed).topLeft
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
    /// before they are drawn. Each goes where the user put it on the displays
    /// connected now, or a projection of that (`placeForCurrentScreens`) —
    /// the displays may have changed while Macterm was quit. A snapshot from
    /// before placements existed has its placement taken from where it was,
    /// if that is still on a screen. A widget already live under the same id
    /// is left alone.
    @discardableResult
    func restoreDesktopWidgets(_ snapshots: [DesktopWidgetSnapshot]) -> Set<UUID> {
        let frames = desktopVisibleFrames()
        var widgets: [DesktopWidget] = []
        for snapshot in snapshots where desktopWidget(id: snapshot.id) == nil {
            let widget = DesktopWidget(
                id: snapshot.id,
                tab: WorkspaceSerializer.restoreTab(snapshot.tab, projectID: DesktopWidget.projectID),
                name: snapshot.name,
                span: DesktopWidgetSpan(columns: snapshot.columns, rows: snapshot.rows),
                topLeft: CGPoint(x: snapshot.topLeftX, y: snapshot.topLeftY),
                command: snapshot.command,
                cwd: snapshot.cwd,
                placements: snapshot.placements ?? []
            )
            if widget.placements.isEmpty, DesktopWidgetGrid.isReachable(widget.frame, on: frames) {
                recordPlacement(of: widget)
            }
            widgets.append(widget)
        }
        placeForCurrentScreens(widgets, avoiding: nativeDesktopWidgetFrames())
        desktopWidgets += widgets
        let restored = Set(widgets.map(\.id))
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
        let alive: Set<String>? = if zmx.isBundled() {
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
                cwd: widget.cwd,
                placements: widget.placements
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
    /// the pinned tabs' capture (`LayoutSerializer.pinnedDeclaration`) under
    /// two of the execution tracker's rules. An idle capture never ERASES an
    /// established `run:`: a pane at its prompt says nothing about what it
    /// should respawn with. And a foreground seen while the shell is AT its
    /// prompt is a prompt hook (`starship prompt`, `mise hook-env`), not a
    /// command — this runs on every change, so it caught them, and a hook
    /// recorded as `run:` is typed into the next fresh shell. `liveCommand`
    /// is the raw sample, injected by tests.
    func refreshDesktopWidgetRecipes(
        liveCommand: (Pane) -> String? = { ProcessInspector.runningCommand(forPane: $0) }
    ) {
        for widget in desktopWidgets where widget.pane?.nsView != nil {
            let declaration = LayoutSerializer.pinnedDeclaration(
                for: widget.tab,
                liveCommand: { pane in pane.isShellAtPrompt ? nil : liveCommand(pane) }
            )
            guard case let .pane(leaf) = declaration.layout else { continue }
            if let cwd = leaf.cwd { widget.cwd = cwd }
            if let run = leaf.run { widget.command = run }
        }
    }

    /// A widget as `widgets.yaml` declares it: the grid cell and display of
    /// where the user last put it (`placements`), never where a display
    /// change projected it — or quitting on the laptop would write the
    /// laptop's cell over the external display's, and the next launch on
    /// that display would adopt it. The display is always named: which one
    /// is primary changes with what is plugged in, so leaving it out
    /// ("the primary display") would mean another display after the change.
    func desktopWidgetDeclaration(_ widget: DesktopWidget) -> WidgetDeclaration {
        let placement = widget.placements.last
        return WidgetDeclaration(
            name: widget.name,
            size: widget.span.description,
            column: placement?.column,
            row: placement?.row,
            display: placement?.display,
            cwd: widget.cwd,
            run: widget.command
        )
    }

    /// Make `widget` what `entry` declares. Name and recipe apply to the next
    /// fresh session; size and place apply now — but only where the entry
    /// says something DIFFERENT from what the widget already declares
    /// (`desktopWidgetDeclaration`). The file's cell is on the screen's
    /// default lattice and cannot express a widget that joined a neighbour's,
    /// so re-deriving an untouched entry moved such a widget off its
    /// neighbour on every launch. Returns whether size or place changed; a
    /// place the caller then records (`tidyDesktopWidgets`).
    ///
    /// A cell on a display that isn't connected, but that the widget has been
    /// on, becomes its placement there for when it is — the widget stays
    /// where it is meanwhile. On a display it has never been on, the cell is
    /// taken on the primary display, as for no `display:` at all.
    @discardableResult
    private func adopt(_ entry: WidgetDeclaration, into widget: DesktopWidget) -> Bool {
        let current = desktopWidgetDeclaration(widget)
        widget.name = entry.name
        widget.command = entry.run
        widget.cwd = entry.cwd
        var moved = false
        if let size = entry.size, size != current.size, let span = DesktopWidgetSpan(parsing: size) {
            widget.span = span
            moved = true
        }
        // No `display:` is the primary display — what every entry written
        // before displays were always named says, so it isn't a change.
        let screens = desktopScreens()
        let display = entry.display ?? screens.first?.name
        guard let column = entry.column, let row = entry.row,
              column != current.column || row != current.row || display != current.display
        else { return moved }
        let cell = (column: max(0, column), row: max(0, row))
        if let display = entry.display, !screens.contains(where: { $0.name == display }),
           let known = widget.placements.last(where: { $0.display == display })
        {
            let offset = CGPoint(
                x: DesktopWidgetGrid.edgeInset.width + CGFloat(cell.column) * DesktopWidgetGrid.pitch,
                y: DesktopWidgetGrid.edgeInset.height + CGFloat(cell.row) * DesktopWidgetGrid.pitch
            )
            widget.placements = DesktopWidgetPlacement.recording(
                DesktopWidgetPlacement(display: display, resolution: known.resolution, offset: offset),
                into: widget.placements
            )
        } else if let screen = screens.first(where: { $0.name == entry.display }) ?? screens.first {
            widget.topLeft = DesktopWidgetGrid.topLeft(column: cell.column, row: cell.row, in: screen.visibleFrame)
            moved = true
        }
        return moved
    }

    /// A widget for an entry the user added by hand: a fresh session running
    /// its recipe, in its declared cell (else the middle of the screen).
    private func makeDeclaredWidget(_ entry: WidgetDeclaration) -> DesktopWidget {
        let widget = makeDesktopWidget(
            span: entry.size.flatMap(DesktopWidgetSpan.init(parsing:)),
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
    ///
    /// Deliberately no snapshot save: this runs inside `restoreSelection`,
    /// before any window has registered, and a save then writes the window
    /// list as absent — one window on the next launch. The next ordinary
    /// save records what changed; a widget removed here that a force-quit's
    /// stale snapshot brings back comes back on an empty session and is
    /// removed again.
    func reconcileWidgetLayoutAtLaunch() {
        unlistedDesktopWidgetIDs = []
        switch widgetLayoutStore.read() {
        case .absent:
            if !desktopWidgets.isEmpty { writeWidgetLayout() }
        case let .invalid(reason):
            suspendWidgetLayoutWrites(reason: reason)
        case let .file(entries, text):
            let matching = WidgetLayoutMatcher.match(entries: entries, current: desktopWidgets.map(desktopWidgetDeclaration))
            let current = desktopWidgets
            var result: [DesktopWidget] = []
            var moved: Set<UUID> = []
            for (entry, index) in matching.pairs {
                if let index {
                    if adopt(entry, into: current[index]) { moved.insert(current[index].id) }
                    result.append(current[index])
                } else {
                    let widget = makeDeclaredWidget(entry)
                    logger.info("widgets.yaml added a widget; created \(widget.id.uuidString, privacy: .public)")
                    desktopWidgets.append(widget)
                    result.append(widget)
                    moved.insert(widget.id)
                }
            }
            for index in matching.removed {
                logger.info("widgets.yaml removed desktop widget \(current[index].id.uuidString, privacy: .public)")
                endSessions(of: current[index])
                pendingDesktopWidgetMaterialize.remove(current[index].id)
            }
            desktopWidgets = result
            tidyDesktopWidgets(moved)
            widgetLayoutLastWrittenText = text
            widgetLayoutLastWrittenIDs = Set(result.map(\.id))
            widgetLayoutSuspended = false
            syncDesktopWidgetPresenter()
        }
    }

    /// Rewrite `widgets.yaml` from the widgets — after absorbing any edit made
    /// since our last write (tracked by exact text). Additions become widgets
    /// and edits apply now. Removing a widget that is running is honored at
    /// launch — an editor's half-saved file can never kill a shell — but its
    /// entry stays out of the file from then on (`unlistedDesktopWidgetIDs`),
    /// so a write can't put back what the user took out. A file that doesn't
    /// parse suspends auto-writes rather than clobbering the user's work.
    /// Nothing is ever created for someone who has never had a widget.
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
            let listed = desktopWidgets.filter { !unlistedDesktopWidgetIDs.contains($0.id) }
            widgetLayoutLastWrittenText = try widgetLayoutStore.write(widgets: listed.map(desktopWidgetDeclaration))
            widgetLayoutLastWrittenIDs = Set(listed.map(\.id))
        } catch {
            logger.error("Failed to write widgets.yaml: \(error, privacy: .public)")
        }
    }

    /// Write-time absorption: the listed widgets adopt the file's order and
    /// entries, additions become widgets, and an entry the user removed takes
    /// its widget out of the file — the widget stays alive, unlisted, until
    /// the next launch removes it. Only a widget our last write listed can
    /// have had its entry removed: one created since is simply unknown to
    /// the file on disk and is carried over. Unlisted widgets take no part
    /// in matching, or a later entry could resurrect one by position.
    private func absorbExternalWidgetEdits(_ entries: [WidgetDeclaration]) {
        logger.info("widgets.yaml changed externally; absorbing before write")
        let unlisted = desktopWidgets.filter { unlistedDesktopWidgetIDs.contains($0.id) }
        let listed = desktopWidgets.filter { widgetLayoutLastWrittenIDs.contains($0.id) && !unlistedDesktopWidgetIDs.contains($0.id) }
        let fresh = desktopWidgets.filter { !widgetLayoutLastWrittenIDs.contains($0.id) && !unlistedDesktopWidgetIDs.contains($0.id) }
        let matching = WidgetLayoutMatcher.match(entries: entries, current: listed.map(desktopWidgetDeclaration))
        var result: [DesktopWidget] = []
        var moved: Set<UUID> = []
        for (entry, index) in matching.pairs {
            if let index {
                if adopt(entry, into: listed[index]) { moved.insert(listed[index].id) }
                result.append(listed[index])
            } else {
                let widget = makeDeclaredWidget(entry)
                result.append(widget)
                moved.insert(widget.id)
            }
        }
        for index in matching.removed {
            logger
                .info(
                    "widgets.yaml no longer lists widget \(listed[index].id.uuidString, privacy: .public); removed at next launch"
                )
            unlistedDesktopWidgetIDs.insert(listed[index].id)
            result.append(listed[index])
        }
        result += fresh
        result += unlisted
        desktopWidgets = result
        tidyDesktopWidgets(moved)
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
