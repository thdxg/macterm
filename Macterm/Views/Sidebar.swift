import SwiftUI
import UniformTypeIdentifiers

/// A sidebar row's content region extends past the selection highlight's
/// trailing edge. A short label never reaches out there, but content that
/// fills the row — split segments, the merge drop slot, a fading title —
/// does, and reads as overflowing the highlight. Every row applies this
/// trailing inset at its root so all of them stop at the same edge.
private let rowTrailingInset: CGFloat = 10

@MainActor
enum SidebarLayoutMetrics {
    static let topContentMargin: CGFloat = 4
    static let idlePinDropHeight: CGFloat = 8

    static func overlayTopBarHeight(windowTopInset: CGFloat) -> CGFloat {
        max(windowTopInset - topContentMargin - idlePinDropHeight, 0)
    }

    static func overlayTopBlurHeight(topBarHeight: CGFloat) -> CGFloat {
        topBarHeight + topContentMargin + idlePinDropHeight
    }
}

/// Keeps the sidebar footer above scrolling rows, using the native macOS 26
/// scroll-edge fade when available.
private extension View {
    @ViewBuilder
    func sidebarTopSafeAreaBar(height: CGFloat) -> some View {
        if height > 0 {
            if #available(macOS 26.0, *) {
                safeAreaBar(edge: .top, spacing: 0) {
                    Color.clear
                        .frame(height: height)
                        .allowsHitTesting(false)
                }
            } else {
                safeAreaInset(edge: .top, spacing: 0) {
                    Color.clear
                        .frame(height: height)
                        .allowsHitTesting(false)
                }
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func sidebarSafeAreaBar(
        isPresented: Bool,
        paintsFallbackBackground: Bool,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if isPresented {
            if #available(macOS 26.0, *) {
                safeAreaBar(edge: .bottom, spacing: 0) {
                    content()
                }
            } else {
                safeAreaInset(edge: .bottom, spacing: 0) {
                    content()
                        .background {
                            if paintsFallbackBackground { MactermTheme.bg }
                        }
                }
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func sidebarScrollEdgeEffects(enabled: Bool) -> some View {
        if enabled {
            if #available(macOS 26.0, *) {
                scrollEdgeEffectStyle(.soft, for: .bottom)
            } else {
                self
            }
        } else {
            self
        }
    }
}

private struct SidebarTopBlurBar: View {
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(.regularMaterial)
            .mask {
                LinearGradient(
                    colors: [.black, .black.opacity(0.9), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(height: height)
            .allowsHitTesting(false)
    }
}

/// In-app drag payload for a sidebar tab row. Carries the tab's identity plus
/// its source project so a drop can tell a same-project reorder from a
/// cross-project move. `TerminalTab` itself is a live reference type (owns
/// surfaces) and must never be encoded/serialized — only these two UUIDs
/// travel, and the drop looks the tab back up by id.
struct MovableTab: Codable, Transferable {
    let tabID: UUID
    let sourceProjectID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mactermTab)
    }
}

/// In-app drag payload for a sidebar project header — the project's id.
/// Project reordering is driven by this drag rather than `List`'s `.onMove`,
/// because `.onMove` puts the whole List in reorder mode and hijacks the tab
/// rows' `.draggable` gesture (so tab drag-and-drop never fired). With both
/// projects and tabs on the Transferable path, they coexist.
struct MovableProject: Codable, Transferable {
    let projectID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .mactermProject)
    }
}

extension UTType {
    static let mactermTab = UTType(exportedAs: "com.thdxg.macterm.tab-move")
    static let mactermProject = UTType(exportedAs: "com.thdxg.macterm.project-move")
}

/// Import-side union of the drag payloads a project HEADER accepts, so a
/// single view can accept all of them through ONE `.dropDestination`. This
/// exists because stacking two `.dropDestination`s (one per payload type) on
/// the same view is non-deterministic: only one of the two registrations
/// wins, and which one flips with unrelated view changes — measured live, the
/// project header accepted project drops in one build and silently rejected
/// them in the next. Never stack drop destinations; widen the payload instead.
/// Import-only: drags still lift as `MovableTab`/`MovableProject` (their
/// `CodableRepresentation` is JSON, which is what the decoders here parse) or,
/// for a pane, as the raw UUID bytes an `NSDraggingSession` writes.
enum SidebarDropItem: Transferable {
    case tab(MovableTab)
    case project(MovableProject)
    case pane(MovablePane)

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .mactermTab) { data in
            try .tab(JSONDecoder().decode(MovableTab.self, from: data))
        }
        DataRepresentation(importedContentType: .mactermProject) { data in
            try .project(JSONDecoder().decode(MovableProject.self, from: data))
        }
        DataRepresentation(importedContentType: .mactermPaneID) { data in
            guard let pane = MovablePane(payload: data) else {
                throw CocoaError(.coderInvalidValue)
            }
            return .pane(pane)
        }
    }
}

/// The narrower union the tab-list ForEach accepts: a tab (reorder/move) or a
/// pane (separate into a new tab), both of which want the insertion offset the
/// ForEach reports. Deliberately NOT `SidebarDropItem` — including the project
/// payload here would make a project drag target the tab rows, which is the
/// state the header comment calls out as broken at this outline level: the
/// insertion line would appear inside a section a project can't land in. The
/// two unions are separate views' payloads, not stacked destinations.
enum TabSlotDropItem: Transferable {
    case tab(MovableTab)
    case pane(MovablePane)

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .mactermTab) { data in
            try .tab(JSONDecoder().decode(MovableTab.self, from: data))
        }
        DataRepresentation(importedContentType: .mactermPaneID) { data in
            guard let pane = MovablePane(payload: data) else {
                throw CocoaError(.coderInvalidValue)
            }
            return .pane(pane)
        }
    }
}

struct SidebarContent: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore
    @AppStorage(Preferences.Keys.showNewProjectButton)
    private var showNewProjectButton = true
    @Bindable
    private var presentation: SidebarPresentationState
    private let isInteractive: Bool
    private let paintsFallbackFooterBackground: Bool
    private let forcesScrollEdgeEffects: Bool
    private let topSafeAreaBarHeight: CGFloat

    init(
        presentation: SidebarPresentationState,
        isInteractive: Bool,
        paintsFallbackFooterBackground: Bool = true,
        forcesScrollEdgeEffects: Bool = false,
        topSafeAreaBarHeight: CGFloat = 0
    ) {
        self.presentation = presentation
        self.isInteractive = isInteractive
        self.paintsFallbackFooterBackground = paintsFallbackFooterBackground
        self.forcesScrollEdgeEffects = forcesScrollEdgeEffects
        self.topSafeAreaBarHeight = topSafeAreaBarHeight
    }

    var body: some View {
        List(selection: $presentation.selection) {
            // Pinned tabs live above every project as flat rows (no header,
            // no disclosure), wrapped in a headerless Section so their ForEach
            // sits inside a container — mirroring the tab ForEach below, whose
            // `.dropDestination` insertion line works there while the same
            // API on a BARE top-level ForEach crashes the outline accept (see
            // the project ForEach's notes below). The drop mechanism is the
            // native insertion line, exactly like a project's tab list: the
            // ForEach reports the insertion offset, a drop pins (or reorders /
            // separates a pane) at that slot, and rows carry NO destinations
            // of their own (a row-level target would kill the line — see
            // `tabRow`). The always-available target — and the ONLY one when
            // no pinned rows exist yet — is the pin drop zone strip above the
            // list (see `PinTabDropZone`).
            Section {
                ForEach(Array(appState.pinnedRecords.enumerated()), id: \.element.id) { index, record in
                    pinnedRow(record: record, index: index)
                }
                .dropDestination(for: TabSlotDropItem.self) { items, offset in
                    for item in items {
                        switch item {
                        case let .tab(tab):
                            receivePinnedTabDrop(tab, at: offset)
                        case let .pane(pane):
                            // The offset counts RECORDS (unloaded rows
                            // included) — the pinned-aware API owns the
                            // conversion to the live-tab index.
                            appState.separatePaneIntoPinned(pane.paneID, atRecordIndex: offset)
                        }
                    }
                }
            }
            ForEach(Array(projectStore.projects.enumerated()), id: \.element.id) { projectIndex, project in
                projectSection(index: projectIndex, project: project)
            }
            // Project reordering is a `MovableProject` drag from one header
            // onto another (see `projectHeader`); the context menus' Move
            // Up/Down are the fallback for precision moves. There is NO
            // insertion-line path for projects — every native mechanism is
            // broken at this outline level, each verified live, so don't
            // re-attempt them:
            // - `.onMove` puts the List in reorder mode and hijacks the tab
            //   rows' `.draggable` (tab drag-and-drop never fired).
            // - `.dropDestination(for:)` on this OUTER ForEach (whose rows
            //   are DisclosureGroups) AND the legacy `.onInsert(of:)` both
            //   crash identically on drop inside SwiftUI's outline machinery
            //   (OutlineListCoordinator.outlineView(_:acceptDrop:…) →
            //   HeterogeneousCollection.element(at:) assertion; macOS 27).
            //   The insertion LINE renders fine during the hover — it is the
            //   accept that dies, so it can't even be risked as a cosmetic.
            //   The tab ForEach below can use the same API because its rows
            //   are one level down in the outline.
            // - A List-level catch-all never fires: the outline view claims
            //   every drag over the sidebar, so unhandled drops don't bubble
            //   to enclosing views.
        }
        // A single list-level context menu instead of one per row: the native
        // multi-select menu. Its closure receives the exact set the menu should
        // act on — right-clicking inside a multi-selection yields all selected
        // rows; right-clicking an unselected row yields just that row. This is
        // what lets "Remove N Projects" / "Close N Tabs" work.
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            contextMenu(for: items)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, SidebarLayoutMetrics.topContentMargin, for: .scrollContent)
        .sidebarTopSafeAreaBar(height: topSafeAreaBarHeight)
        .sidebarScrollEdgeEffects(enabled: forcesScrollEdgeEffects)
        .scrollPosition(id: Binding(
            get: { presentation.scrollPosition },
            set: { position in
                guard isInteractive else { return }
                presentation.scrollPosition = position
            }
        ))
        // The pin drop zone: a strip above the list. It lives OUTSIDE the
        // List on purpose — a plain view's `.dropDestination` has none of the
        // outline view's drop hazards (see the notes inside the List body),
        // and it exists even with zero pinned rows, so the FIRST pin can be a
        // drag too. It only draws its "Pin Tab" band in exactly that case:
        // once a pinned row exists, the native insertion line above it says
        // the same thing, and the band on top of it is noise.
        .safeAreaInset(edge: .top, spacing: 0) {
            // Same handlers as the insertion line, fixed at the first slot
            // — the strip and the line are one operation, so a routing fix
            // in one can't strand the other.
            PinTabDropZone(
                showsBand: appState.pinnedRecords.isEmpty,
                onPinTab: { receivePinnedTabDrop($0, at: 0) },
                onPinPane: { appState.separatePaneIntoPinned($0.paneID, atRecordIndex: 0) }
            )
        }
        .sidebarSafeAreaBar(
            isPresented: showNewProjectButton,
            paintsFallbackBackground: paintsFallbackFooterBackground
        ) {
            HStack(spacing: 0) {
                Menu {
                    Button("Local Folder…") { openProject() }
                    Button("Remote Machine…") {
                        appState.isNewRemoteProjectSheetPresented = true
                    }
                } label: {
                    Label("New Project", systemImage: "plus")
                        .font(.body)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 36)
            // Not 16: the two edges are padding the label's *layout* box, whose
            // slack differs per edge — the leading side bearing of the `plus`
            // symbol pushes its ink ~4.5pt in, while the line box ends ~0.5pt
            // below the text's descender. Measured on a build, 16/20 is what
            // puts the ink an equal ~20.5pt off both the left and bottom edges.
            .padding(.bottom, 20)
        }
        .onChange(of: presentation.selection) { _, items in
            // Navigation follows a single selection only. A multi-selection is
            // for bulk actions (delete), so it must not yank the active project
            // or tab around as rows are added to the selection.
            guard isInteractive, items.count == 1, let item = items.first else { return }
            switch item {
            case let .project(projectID):
                guard let project = projectStore.projects.first(where: { $0.id == projectID }) else { return }
                appState.selectProject(project)
            case let .tab(PinnedTabs.projectID, tabID):
                // Loaded → select; unloaded → restore from declaration.
                appState.selectPinnedTab(tabID)
            case let .tab(projectID, tabID):
                if let project = projectStore.projects.first(where: { $0.id == projectID }) {
                    appState.selectProject(project)
                    appState.selectTab(tabID, projectID: projectID)
                }
            }
        }
        .onChange(of: appState.activeProjectID) { _, newID in
            if let newID, newID != PinnedTabs.projectID {
                presentation.expandedProjects.insert(newID)
            }
            syncSelection()
        }
        .onChange(of: activeTabID) {
            syncSelection()
        }
        .onAppear {
            presentation.restoreExpansionOnce(
                projectIDs: projectStore.projects.map(\.id),
                activeProjectID: appState.activeProjectID,
                restoreAllProjects: Preferences.shared.restoreAllProjectsOnLaunch
            )
            syncSelection()
        }
        .overlay(alignment: .top) {
            if topSafeAreaBarHeight > 0 {
                SidebarTopBlurBar(
                    height: SidebarLayoutMetrics.overlayTopBlurHeight(topBarHeight: topSafeAreaBarHeight)
                )
            }
        }
    }

    // MARK: - Pinned rows

    /// One pinned row: loaded (a live tab, standard row treatment with a pin
    /// icon) or unloaded (dimmed; selecting it rebuilds the tab from its
    /// declaration). Draggable only — drops are the enclosing ForEach's
    /// native insertion line (see `body`), and a row-level destination would
    /// kill it, same as `tabRow` documents.
    private func pinnedRow(record: PinnedTabRecord, index: Int) -> some View {
        Group {
            if let tab = appState.pinnedWorkspace?.tabs.first(where: { $0.id == record.id }) {
                // The shared row with the pin as its fixed icon — pinned rows
                // have no project section around them, so the pin is what
                // says which rows these are.
                SidebarTabRow(
                    tab: tab,
                    index: index + 1,
                    iconSymbolOverride: "pin",
                    presentation: presentation,
                    isInteractive: isInteractive,
                    onRename: { newName in
                        tab.customTitle = newName.isEmpty ? nil : newName
                        appState.saveWorkspaces()
                    }
                )
            } else {
                // Unloaded: the sessions ended (a close, or their own death).
                // The row stays; selecting it restores from the layout.
                Label {
                    FadingText(record.displayTitle)
                        .foregroundStyle(.secondary)
                } icon: {
                    // The pin stays as-is — the row is still pinned, it just
                    // isn't running; the dimming is what says so. Swapping in
                    // `pin.slash` read as "unpinned", which is the one thing
                    // closing a pinned tab never does.
                    Image(systemName: "pin")
                        .foregroundStyle(.tertiary)
                }
                .help("Not running — select to restore from its saved layout")
            }
        }
        .padding(.trailing, rowTrailingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(SidebarItem.tab(projectID: PinnedTabs.projectID, tabID: record.id))
        .id(SidebarItem.tab(projectID: PinnedTabs.projectID, tabID: record.id))
        // Dragging a pinned row into a project unpins it (AppState.moveTab
        // routes the record bookkeeping). Deliberately NO drop destination on
        // the row — same rule as `tabRow`: any row-level target claims the
        // drag before the ForEach's insertion mechanism sees it and kills the
        // native insertion line.
        .draggable(MovableTab(tabID: record.id, sourceProjectID: PinnedTabs.projectID))
    }

    /// A tab dropped at a pinned insertion offset (the ForEach's native
    /// insertion line): from a project → pin there; from within the pinned
    /// rows → reorder (`reorderPinnedTab` speaks the same pre-removal offset).
    private func receivePinnedTabDrop(_ item: MovableTab, at offset: Int) {
        if item.sourceProjectID == PinnedTabs.projectID {
            appState.reorderPinnedTab(item.tabID, toIndex: offset)
        } else {
            appState.pinTab(item.tabID, fromProject: item.sourceProjectID, toRecordIndex: offset)
        }
    }

    /// One project's disclosure section: its tab rows (draggable + a drop
    /// target that reorders/moves at the insertion offset) under a header that
    /// itself accepts drops (the append path for a collapsed/empty project).
    /// Extracted from `body` so each drag/drop closure type-checks in its own
    /// scope — inlined, the whole `List` blew the solver's time budget.
    @ViewBuilder
    private func projectSection(index projectIndex: Int, project: Project) -> some View {
        let ws = appState.workspaces[project.id]
        let tabs = ws?.tabs ?? []
        DisclosureGroup(isExpanded: Binding(
            get: { presentation.expandedProjects.contains(project.id) },
            set: {
                if $0 {
                    presentation.expandedProjects.insert(project.id)
                } else {
                    presentation.expandedProjects.remove(project.id)
                }
            }
        )) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { tabIndex, tab in
                tabRow(tab: tab, index: tabIndex, project: project)
            }
            // Single drop mechanism for every case: SwiftUI reports the
            // insertion `offset` within THIS project's tab list. A tab drop
            // from the same project reorders to that slot; one from another
            // project moves the tab in at that slot; a PANE drop (the grab
            // handle drag from the workspace) separates that pane into a new
            // tab landing at the same slot. Replaces the old `.onMove` (which
            // is per-section and can't express a cross-project move).
            .dropDestination(for: TabSlotDropItem.self) { items, offset in
                for item in items {
                    switch item {
                    case let .tab(tab):
                        receiveTabDrop([tab], into: project, at: offset)
                    case let .pane(pane):
                        receivePaneDrop([pane], into: project, at: offset)
                    }
                }
            }
        } label: {
            projectHeader(index: projectIndex, project: project)
        }
        .id(SidebarItem.project(project.id))
    }

    private func tabRow(tab: TerminalTab, index tabIndex: Int, project: Project) -> some View {
        SidebarTabRow(
            tab: tab,
            index: tabIndex + 1,
            presentation: presentation,
            isInteractive: isInteractive,
            // An unloaded project keeps its tabs as a layout with no shells
            // behind them — the same state a closed pinned tab is in, so it
            // gets the same dimmed treatment.
            isUnloaded: appState.isProjectUnloaded(project.id),
            onRename: { newName in
                tab.customTitle = newName.isEmpty ? nil : newName
                appState.saveWorkspaces()
            }
        )
        .padding(.trailing, rowTrailingInset)
        // Stretch to the full row and make every point hit-testable: without
        // this, the drag grab area hugs the label's intrinsic width instead
        // of covering the whole row.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(SidebarItem.tab(projectID: project.id, tabID: tab.id))
        .id(SidebarItem.tab(projectID: project.id, tabID: tab.id))
        // Drag a tab out to another project (or reorder within this one). The
        // payload is just IDs — the live tab is looked up on drop, never
        // serialized.
        .draggable(MovableTab(tabID: tab.id, sourceProjectID: project.id))
        // Deliberately NO drop destination on tab rows. Any destination here
        // — even one registered for the project payload alone — claims every
        // drag over the row before the tab ForEach's insertion mechanism sees
        // it (SwiftUI routes a drag to the topmost target by geometry with no
        // type fall-through), which kills the native insertion line and broke
        // tab reordering outright when tried. The cost is that a PROJECT drag
        // over an expanded section's tab rows has nothing to land on — drop
        // it on a project header instead. The insertion line won.
    }

    private func projectHeader(index projectIndex: Int, project: Project) -> some View {
        SidebarProjectRow(
            project: project,
            index: projectIndex + 1,
            presentation: presentation,
            isInteractive: isInteractive
        ) {
            projectStore.rename(id: project.id, to: $0)
        }
        .padding(.trailing, rowTrailingInset)
        // Stretch to the full row so the drag grab area (and the drop band in
        // the background below) covers the whole row, not just the label's
        // intrinsic width — same treatment as the tab rows.
        .frame(maxWidth: .infinity, alignment: .leading)
        .tag(SidebarItem.project(project.id))
        // Drag the header to reorder projects (replaces the removed `.onMove`).
        .draggable(MovableProject(projectID: project.id))
        // ONE drop destination for every payload (see `SidebarDropItem` for
        // why stacking two is a landmine). A TAB dropped here appends to this
        // project — the only drop path for a collapsed or empty project,
        // whose tab ForEach renders no rows to target — and a PANE dropped
        // here appends its new tab the same way. A PROJECT dropped
        // squarely on the header reorders it to this project's slot; the
        // seams BETWEEN rows deliberately stay uncovered (label-height
        // target, no taller band) so the ForEach-level insertion line can
        // appear there for both drag kinds.
        .dropDestination(for: SidebarDropItem.self) { items, _ in
            for item in items {
                switch item {
                case let .tab(tab):
                    receiveTabDrop([tab], into: project, at: nil)
                case let .project(dragged):
                    receiveProjectDrop([dragged], before: project)
                case let .pane(pane):
                    receivePaneDrop([pane], into: project, at: nil)
                }
            }
            return true
        } isTargeted: { targeted in
            // Spring-open a collapsed project while hovering a drag over it,
            // so the user can see where a tab will land. This also fires for
            // project drags (the union payload can't be inspected here); the
            // hovered header itself doesn't move when it expands, so the
            // drop stays on target.
            if targeted { presentation.expandedProjects.insert(project.id) }
        }
    }

    private var activeTabID: UUID? {
        guard let pid = appState.activeProjectID else { return nil }
        return appState.workspaces[pid]?.activeTabID
    }

    /// Apply a tab drag-and-drop. `index` is the insertion slot within the
    /// destination project's tab list (nil = append, used by header drops). A
    /// drop from the same project reorders; a drop from another project moves
    /// the live tab (surfaces and shells intact) into this one. SwiftUI can
    /// deliver more than one payload, so each is applied in order.
    private func receiveTabDrop(_ items: [MovableTab], into project: Project, at index: Int?) {
        for item in items {
            if item.sourceProjectID == project.id {
                if let index {
                    appState.reorderTab(item.tabID, inProject: project.id, toIndex: index)
                }
            } else {
                appState.moveTab(
                    item.tabID,
                    from: item.sourceProjectID,
                    to: project.id,
                    destPath: project.path,
                    toIndex: index
                )
            }
        }
        presentation.expandedProjects.insert(project.id)
    }

    /// Apply a pane drag-and-drop: the pane leaves its split tree and becomes
    /// its own tab in this project, at `index` (nil = append, used by header
    /// drops). The `Pane` object — and its live surface and shell — is reused,
    /// the same as the Separate Current Pane command, which calls the same
    /// `AppState.separatePane`. Dragging a tab's ONLY pane here is a no-op:
    /// it already is its own tab, and moving it to another project is what
    /// dragging its sidebar row does.
    private func receivePaneDrop(_ items: [MovablePane], into project: Project, at index: Int?) {
        for item in items {
            appState.separatePane(
                item.paneID,
                toProject: project.id,
                destPath: project.path,
                at: index
            )
        }
        presentation.expandedProjects.insert(project.id)
    }

    /// Apply a project drag-and-drop onto a section (header or tab row): move
    /// the dragged project to the target project's slot. Uses
    /// `move(fromOffsets:toOffset:)` semantics — `toOffset` is the index in
    /// the CURRENT array where the item inserts (SwiftUI's convention), so a
    /// downward move lands after the target.
    private func receiveProjectDrop(_ items: [MovableProject], before target: Project) {
        let projects = projectStore.projects
        guard let targetIndex = projects.firstIndex(where: { $0.id == target.id }) else { return }
        for item in items {
            guard let fromIndex = projects.firstIndex(where: { $0.id == item.projectID }),
                  fromIndex != targetIndex
            else { continue }
            // Dropping onto a project means "land at its slot": inserting above
            // when dragging up, and (via move's toOffset convention) at the
            // target's position when dragging down.
            let toOffset = fromIndex < targetIndex ? targetIndex + 1 : targetIndex
            projectStore.reorder(fromOffsets: IndexSet(integer: fromIndex), toOffset: toOffset)
        }
    }

    private func syncSelection() {
        guard let pid = appState.activeProjectID,
              let ws = appState.workspaces[pid],
              let tabID = ws.activeTabID
        else {
            presentation.selection = appState.activeProjectID.map { [.project($0)] } ?? []
            return
        }
        let desired: Set<SidebarItem> = [.tab(projectID: pid, tabID: tabID)]
        if presentation.selection != desired { presentation.selection = desired }
    }

    // MARK: - Context menu

    /// The native multi-select context menu. `items` is the set the menu acts
    /// on, supplied by SwiftUI: the whole selection when the click lands inside
    /// it, or just the clicked row otherwise.
    @ViewBuilder
    private func contextMenu(for items: Set<SidebarItem>) -> some View {
        if items.count > 1 {
            bulkMenu(for: items)
        } else if let item = items.first {
            switch item {
            case let .project(id):
                if let project = projectStore.projects.first(where: { $0.id == id }) {
                    projectMenu(project)
                }
            case let .tab(PinnedTabs.projectID, tabID):
                if let record = appState.pinnedRecord(tabID) {
                    pinnedTabMenu(record: record)
                }
            case let .tab(projectID, tabID):
                if let project = projectStore.projects.first(where: { $0.id == projectID }),
                   let tab = appState.workspaces[projectID]?.tabs.first(where: { $0.id == tabID })
                {
                    tabMenu(project: project, tab: tab)
                }
            }
        } else {
            // Right-click on empty space.
            Menu("New Project") {
                Button("Local Folder…") { openProject() }
                Button("Remote Machine…") { appState.isNewRemoteProjectSheetPresented = true }
            }
        }
    }

    /// Single-project menu. Destructive actions route through the same
    /// `request*` confirmations the maintainers added for busy panes, so a
    /// single right-click behaves exactly as before this feature.
    @ViewBuilder
    private func projectMenu(_ project: Project) -> some View {
        Button("New Tab") {
            appState.selectProject(project)
            appState.createTab(projectID: project.id, projectPath: project.path)
            presentation.expandedProjects.insert(project.id)
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.path, forType: .string)
        }
        Divider()
        Button("Rename Project") { requestProjectRename(project.id) }
        Divider()
        // Same reorder calls as Settings → Projects' rows; `toOffset` is in
        // `move(fromOffsets:toOffset:)` convention, hence `+ 2` for down.
        let index = projectStore.projects.firstIndex(where: { $0.id == project.id }) ?? 0
        Button("Move Up") {
            projectStore.reorder(fromOffsets: [index], toOffset: index - 1)
        }
        .disabled(index <= 0)
        Button("Move Down") {
            projectStore.reorder(fromOffsets: [index], toOffset: index + 2)
        }
        .disabled(index >= projectStore.projects.count - 1)
        Divider()
        Button("Unload Project") { appState.requestUnloadProject(project.id) }
            .disabled(!appState.isProjectLoaded(project.id))
        Button("Remove Project", role: .destructive) {
            appState.requestRemoveProject(project.id) { removeProject(project) }
        }
    }

    /// A pinned row's menu — two exits with distinct semantics: Unpin (a
    /// move back to a project for a loaded tab, nothing killed; forgetting
    /// the declaration for an unloaded record — the removal path) and Close
    /// (an unload: processes end, the row and layout stay), matching the
    /// normal tab menu's Close Tab.
    @ViewBuilder
    private func pinnedTabMenu(record: PinnedTabRecord) -> some View {
        let isLoaded = appState.isPinnedTabLoaded(record.id)
        if isLoaded {
            Button("Rename Tab") { requestTabRename(record.id) }
            if let tab = appState.pinnedWorkspace?.tabs.first(where: { $0.id == record.id }),
               tab.splitRoot.allPanes().count > 1
            {
                Button("Separate Panes") {
                    appState.separateTabPanes(record.id, projectID: PinnedTabs.projectID)
                }
            }
            Divider()
        }
        let index = appState.pinnedRecords.firstIndex(where: { $0.id == record.id }) ?? 0
        Button("Move Up") {
            appState.reorderPinnedTab(record.id, toIndex: index - 1)
        }
        .disabled(index <= 0)
        Button("Move Down") {
            appState.reorderPinnedTab(record.id, toIndex: index + 2)
        }
        .disabled(index >= appState.pinnedRecords.count - 1)
        if isLoaded, !projectStore.projects.isEmpty {
            Menu("Unpin to Project") {
                ForEach(projectStore.projects) { destination in
                    Button(destination.name) {
                        appState.moveTab(
                            record.id,
                            from: PinnedTabs.projectID,
                            to: destination.id,
                            destPath: destination.path
                        )
                        presentation.expandedProjects.insert(destination.id)
                    }
                }
            }
        }
        Divider()
        // Unpin = a MOVE back to the origin project for a loaded tab (nothing
        // killed); an unloaded record has no live tab, so unpinning forgets
        // the declaration — how a dead row is removed.
        Button("Unpin Tab") {
            appState.unpinTab(record.id, projects: projectStore.projects)
        }
        if isLoaded {
            // Close = UNLOAD: processes end, the dimmed row and its saved
            // layout stay, and the next launch starts it again. Same entry
            // point as the normal tab menu's Close Tab and the closeTab
            // command — `requestCloseTab` routes pinned tabs to the unload.
            Button("Close Tab", role: .destructive) {
                appState.requestCloseTab(record.id, projectID: PinnedTabs.projectID)
            }
        }
    }

    @ViewBuilder
    private func tabMenu(project: Project, tab: TerminalTab) -> some View {
        Button("Rename Tab") { requestTabRename(tab.id) }
        if tab.splitRoot.allPanes().count > 1 {
            // #227: explode a split tab — every pane after the first opens in
            // its own tab, shells intact.
            Button("Separate Panes") { appState.separateTabPanes(tab.id, projectID: project.id) }
        }
        Divider()
        // `reorderTab` takes `move(fromOffsets:toOffset:)`-convention offsets
        // (it's the drag-and-drop path's entry point), hence `+ 2` for down.
        let tabs = appState.workspaces[project.id]?.tabs ?? []
        let tabIndex = tabs.firstIndex(where: { $0.id == tab.id }) ?? 0
        Button("Move Up") {
            appState.reorderTab(tab.id, inProject: project.id, toIndex: tabIndex - 1)
        }
        .disabled(tabIndex <= 0)
        Button("Move Down") {
            appState.reorderTab(tab.id, inProject: project.id, toIndex: tabIndex + 2)
        }
        .disabled(tabIndex >= tabs.count - 1)
        let moveTargets = projectStore.projects.filter { $0.id != project.id }
        if !moveTargets.isEmpty {
            Menu("Move to Project") {
                ForEach(moveTargets) { destination in
                    Button(destination.name) {
                        appState.moveTab(tab.id, from: project.id, to: destination.id, destPath: destination.path)
                        presentation.expandedProjects.insert(destination.id)
                    }
                }
            }
        }
        Button("Pin Tab") {
            appState.pinTab(tab.id, fromProject: project.id)
        }
        Divider()
        Button("Close Tab", role: .destructive) {
            appState.requestCloseTab(tab.id, projectID: project.id)
        }
    }

    @ViewBuilder
    private func bulkMenu(for items: Set<SidebarItem>) -> some View {
        let projectCount = items.count(where: { if case .project = $0 { true } else { false } })
        let tabCount = items.count - projectCount
        if projectCount == 0 {
            Button("Close \(tabCount) Tabs", role: .destructive) { removeSelection(items) }
        } else if tabCount == 0 {
            Button("Remove \(projectCount) Projects", role: .destructive) { removeSelection(items) }
        } else {
            Button("Remove \(items.count) Items", role: .destructive) { removeSelection(items) }
        }
    }

    /// Remove a single project: drop its workspace and its `ProjectStore` entry,
    /// and collapse its disclosure. Shared by the single-item menu and the
    /// bulk path so both prune identically.
    private func removeProject(_ project: Project) {
        presentation.expandedProjects.remove(project.id)
        appState.removeProject(project.id)
        projectStore.remove(id: project.id)
    }

    /// Delete every item in a multi-selection, confirming once if any affected
    /// pane is busy. Tabs whose project is also being removed are skipped —
    /// `removeProject` already tears their surfaces down.
    private func removeSelection(_ items: Set<SidebarItem>) {
        var projectIDs: [UUID] = []
        var tabRefs: [(tabID: UUID, projectID: UUID)] = []
        for item in items {
            switch item {
            case .project(PinnedTabs.projectID):
                // The pinned section can't be removed.
                break
            case let .project(id):
                projectIDs.append(id)
            case let .tab(projectID, tabID):
                // Pinned tabs are included: `closeTabs` routes them to the
                // unload path (record kept), matching a single-row close.
                tabRefs.append((tabID: tabID, projectID: projectID))
            }
        }

        let removedProjects = Set(projectIDs)
        let tabsToClose = tabRefs.filter { !removedProjects.contains($0.projectID) }
        let projects = projectStore.projects.filter { removedProjects.contains($0.id) }

        appState.requestRemoveSelection(projectIDs: projectIDs, tabs: tabsToClose) {
            appState.closeTabs(tabsToClose)
            for project in projects {
                removeProject(project)
            }
            presentation.selection = []
        }
    }

    private func openProject() {
        if let project = appState.openProject(store: projectStore) {
            presentation.expandedProjects.insert(project.id)
        }
    }

    private func requestProjectRename(_ projectID: UUID) {
        appState.sidebarVisible = true
        DispatchQueue.main.async { appState.renamingProjectID = projectID }
    }

    private func requestTabRename(_ tabID: UUID) {
        appState.sidebarVisible = true
        DispatchQueue.main.async { appState.renamingTabID = tabID }
    }
}

private struct SidebarProjectRow: View {
    let project: Project
    let index: Int
    @Bindable
    var presentation: SidebarPresentationState
    let isInteractive: Bool
    let onRename: (String) -> Void
    @Environment(AppState.self)
    private var appState
    @AppStorage(Preferences.Keys.projectIconSymbol)
    private var projectIconSymbol = "folder"
    @FocusState
    private var focused: Bool

    private var renameTarget: SidebarRenameTarget { .project(project.id) }

    @ViewBuilder
    private var titleContent: some View {
        if isInteractive, presentation.isRenaming(renameTarget) {
            TextField("", text: $presentation.renameText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { cancelRename() }
                .onAppear { focused = true }
        } else {
            HStack(spacing: 4) {
                FadingText(project.name)
                if project.isRemote {
                    // Remote project (#104): panes live on this host over ssh.
                    Image(systemName: "network")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(project.path)
                }
            }
        }
    }

    var body: some View {
        Group {
            if projectIconSymbol == Preferences.noIcon {
                titleContent
                    .padding(.leading, 6)
            } else {
                Label {
                    titleContent
                } icon: {
                    SidebarRowIcon(symbol: projectIconSymbol, index: index)
                }
            }
        }
        .task(id: appState.renamingProjectID) {
            if appState.renamingProjectID == project.id { beginRename() }
        }
    }

    private func beginRename() {
        guard isInteractive else { return }
        presentation.beginRename(
            renameTarget,
            text: project.name
        )
        appState.renamingProjectID = nil
    }

    private func commit() {
        guard let draft = presentation.completeRename(renameTarget) else { return }
        let text = draft.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { onRename(text) }
        appState.restoreFocusToActivePane()
    }

    private func cancelRename() {
        guard presentation.cancelRename(renameTarget) else { return }
        appState.restoreFocusToActivePane()
    }
}

private struct SidebarTabRow: View {
    let tab: TerminalTab
    let index: Int
    /// Fixed icon overriding the user's `tabIconSymbol` preference — the
    /// pinned rows pass "pin" so the icon itself marks the row's kind.
    var iconSymbolOverride: String?
    @Bindable
    var presentation: SidebarPresentationState
    let isInteractive: Bool
    /// Dim the row: the tab is a layout with no shells behind it (its project
    /// was unloaded). Matches the unloaded pinned row's treatment — secondary
    /// title, tertiary icon, and a tooltip saying what selecting it does.
    var isUnloaded = false
    let onRename: (String) -> Void
    @Environment(AppState.self)
    private var appState
    @AppStorage(Preferences.Keys.tabIconSymbol)
    private var tabIconSymbol = "terminal"
    @AppStorage(Preferences.Keys.showAgentIcons)
    private var showAgentIcons = true
    @AppStorage(Preferences.Keys.showTabStatusIndicator)
    private var showTabStatusIndicator = false
    @AppStorage(Preferences.Keys.showSpinnerOverAgentIcons)
    private var showSpinnerOverAgentIcons = true
    @FocusState
    private var focused: Bool

    private var renameTarget: SidebarRenameTarget { .tab(tab.id) }

    @ViewBuilder
    private var titleContent: some View {
        if isInteractive, presentation.isRenaming(renameTarget) {
            TextField(tab.autoTitle, text: $presentation.renameText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { cancelRename() }
                .onAppear { focused = true }
        } else {
            TabRowTitle(tab: tab)
        }
    }

    /// The tab's live agent logo, unless disabled in Settings.
    private var agentIcon: AgentIcon? {
        showAgentIcons ? tab.agentIcon : nil
    }

    /// The effective icon symbol: the override wins over the preference.
    private var iconSymbol: String {
        iconSymbolOverride ?? tabIconSymbol
    }

    var body: some View {
        Group {
            if iconSymbol == Preferences.noIcon {
                Label {
                    titleContent
                } icon: {
                    if showTabStatusIndicator, tab.executionState != .idle || agentIcon != nil {
                        // Only give the label an icon while the status glyph
                        // actually draws something (spinner, done dot, agent
                        // logo). An idle status with "None" renders the
                        // sentinel as an invisible Image that still reserves
                        // the icon column, nudging the title right of every
                        // other icon-less row.
                        TabStatusGlyph(
                            state: tab.executionState,
                            symbol: iconSymbol,
                            index: index,
                            agent: agentIcon,
                            spinnerOverAgent: showSpinnerOverAgentIcons
                        )
                    } else if let agentIcon {
                        // "None" suppresses the user's icon, not the agent
                        // logo — a live status signal, like the else branch.
                        SidebarRowIcon(symbol: iconSymbol, index: index, agent: agentIcon)
                            .foregroundStyle(.secondary)
                    }
                }
                .labelStyle(.titleAndIcon)
            } else {
                Label {
                    titleContent
                } icon: {
                    if showTabStatusIndicator {
                        TabStatusGlyph(
                            state: tab.executionState,
                            symbol: iconSymbol,
                            index: index,
                            agent: agentIcon,
                            spinnerOverAgent: showSpinnerOverAgentIcons
                        )
                    } else {
                        SidebarRowIcon(symbol: iconSymbol, index: index, agent: agentIcon)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: appState.renamingTabID) { _, id in
            if id == tab.id { beginRename() }
        }
        // Applied only when unloaded: a live row must inherit the List's own
        // styling, and forcing `.primary` back would flatten the white label
        // AppKit gives a selected row.
        .modifier(UnloadedRowStyle(isUnloaded: isUnloaded))
    }

    private func beginRename() {
        guard isInteractive else { return }
        presentation.beginRename(
            renameTarget,
            text: tab.customTitle ?? "",
            originalCustomTitle: tab.customTitle
        )
        appState.renamingTabID = nil
    }

    private func commit() {
        guard let draft = presentation.completeRename(renameTarget) else { return }
        let text = draft.text.trimmingCharacters(in: .whitespaces)
        let newCustomTitle: String? = text.isEmpty ? nil : text
        if newCustomTitle != draft.originalCustomTitle {
            onRename(text)
        }
        appState.restoreFocusToActivePane()
    }

    private func cancelRename() {
        guard presentation.cancelRename(renameTarget) else { return }
        appState.restoreFocusToActivePane()
    }
}

/// The pin drop zone at the top of the sidebar: a strip that pins a dropped
/// tab or pane at the first slot. It draws chrome only when there are no
/// pinned rows yet (`showsBand`) — with rows present the List's own insertion
/// line already marks the same slot, so the band would just double it. Either
/// way the strip must keep a nonzero idle height: `isTargeted` only fires once
/// the pointer is over the target, so a zero-height strip could never be
/// discovered by a drag.
private struct PinTabDropZone: View {
    let showsBand: Bool
    let onPinTab: (MovableTab) -> Void
    let onPinPane: (MovablePane) -> Void
    @State
    private var isTargeted = false

    private var isBandVisible: Bool { showsBand && isTargeted }

    var body: some View {
        ZStack {
            if isBandVisible {
                Label("Pin Tab", systemImage: "pin.fill")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(MactermTheme.accent)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(MactermTheme.accent.opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(MactermTheme.accent.opacity(0.5), lineWidth: 1)
                            )
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: isBandVisible ? 38 : SidebarLayoutMetrics.idlePinDropHeight)
        .contentShape(Rectangle())
        .dropDestination(for: TabSlotDropItem.self) { items, _ in
            for item in items {
                switch item {
                case let .tab(tab):
                    onPinTab(tab)
                case let .pane(pane):
                    onPinPane(pane)
                }
            }
            return true
        } isTargeted: { targeted in
            withAnimation(.easeInOut(duration: 0.15)) {
                isTargeted = targeted
            }
        }
    }
}

/// A tab row's display title, shared by project and pinned rows so the two
/// render identically. #227: an unnamed split of 2-3 panes reads as multiple
/// tabs sharing one row — one chromeless title segment per pane, divided by
/// hairlines so adjacent titles don't read as one run-on name. A custom
/// title still wins (the user named the whole tab), and four or more panes
/// won't fit legibly, so that row collapses back to a single title with the
/// pane count (see `sidebarRowTitle`). The segments are a TITLE variant, not
/// their own labels: the row carries one tab icon regardless.
/// The dimmed treatment shared by every "not running" sidebar row: a tab
/// whose project was unloaded, and — spelled out inline, since it has no live
/// tab to render — a closed pinned tab.
private struct UnloadedRowStyle: ViewModifier {
    let isUnloaded: Bool

    func body(content: Content) -> some View {
        if isUnloaded {
            content
                .foregroundStyle(.secondary)
                .help("Not running — select to load the project again")
        } else {
            content
        }
    }
}

private struct TabRowTitle: View {
    let tab: TerminalTab

    var body: some View {
        if tab.customTitle == nil, (2 ... 3).contains(tab.splitRoot.allPanes().count) {
            HStack(spacing: 10) {
                ForEach(Array(tab.splitRoot.allPanes().enumerated()), id: \.element.id) { i, pane in
                    if i > 0 { Divider() }
                    FadingText(pane.sidebarSegmentTitle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            FadingText(tab.sidebarRowTitle)
        }
    }
}

/// The tab icon with a coexisting status indicator (the maintainer's
/// suggestion): the user's chosen icon stays put, and status is additive.
///
/// - `running`: a small spinner replaces the icon (temporary prominence,
///   Xcode-build-navigator style) — unless the icon is an AI agent's logo and
///   the user turned "Show spinner over agent icons" off (#225): agent CLIs
///   draw their own busy indicator in the tab title, so the logo can stay put.
/// - `done` (needs attention): the icon with a small solid status dot in the
///   bottom-trailing corner — like the Messages/FaceTime "available" dot. A
///   dot reads as "done/positive" without competing with the icon's identity,
///   and it avoids the heavy, off-platform look of a checkmark glyph badge.
///   It overlays the agent logo the same way, regardless of the spinner
///   preference — "unread agent messages" is the signal #225 asked to keep.
/// - `idle`: the icon as-is.
private struct TabStatusGlyph: View {
    let state: TerminalExecutionState
    let symbol: String
    let index: Int
    var agent: AgentIcon?
    var spinnerOverAgent = true
    @AppStorage(Preferences.Keys.sidebarIconSize)
    private var iconSizeRaw = SidebarIconSize.medium.rawValue

    private var size: SidebarIconSize {
        SidebarIconSize(rawValue: iconSizeRaw) ?? .medium
    }

    /// The spinner is a control, so it steps between AppKit's control sizes
    /// rather than scaling continuously with the icons. `.mini` (12pt) matches
    /// a small symbol closely; `.regular` is 32pt, far past even a large one,
    /// so large stays on `.small` and only its frame grows.
    private var spinnerControlSize: ControlSize {
        size == .small ? .mini : .small
    }

    var body: some View {
        switch state {
        case .running:
            if let agent, !spinnerOverAgent {
                SidebarRowIcon(symbol: symbol, index: index, agent: agent)
                    .foregroundStyle(.secondary)
                    .help("Running")
            } else {
                let side = 16 * size.glyphScale
                ProgressView()
                    .controlSize(spinnerControlSize)
                    .tint(.secondary)
                    .help("Running")
                    .frame(width: side, height: side)
            }
        case .done:
            SidebarRowIcon(symbol: symbol, index: index, agent: agent)
                .foregroundStyle(.secondary)
                .overlay(alignment: .bottomTrailing) {
                    // Opaque (not translucent) so it reads clearly over the
                    // icon and the sidebar background. Nested in a background
                    // ring so it stays legible over any icon color. Sized off
                    // the icon so the dot keeps hugging its corner at every
                    // icon size instead of floating away from a smaller glyph.
                    Circle()
                        .fill(.background)
                        .frame(width: 7 * size.glyphScale, height: 7 * size.glyphScale)
                        .overlay(
                            Circle()
                                .fill(MactermTheme.success)
                                .frame(width: 5 * size.glyphScale, height: 5 * size.glyphScale)
                        )
                        .offset(x: 2.5 * size.glyphScale, y: 2.5 * size.glyphScale)
                }
                .help("Done")
        case .idle:
            SidebarRowIcon(symbol: symbol, index: index, agent: agent)
                .foregroundStyle(.secondary)
                .help("Idle")
        }
    }
}

private extension AgentIcon {
    /// The agent's brand tint. These are vendor identity colors, not theme
    /// colors, so they're the one deliberate exception to "all colors come
    /// from MactermTheme". Monochrome brands (Cursor, Grok, opencode) use
    /// `.primary` so they stay black-on-light / white-on-dark like the brand.
    var brandColor: Color {
        switch self {
        case .claude: Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255) // Anthropic coral
        case .codex: Color(red: 0xAB / 255, green: 0xAB / 255, blue: 0xAB / 255) // OpenAI light gray
        case .gemini: Color(red: 0x42 / 255, green: 0x85 / 255, blue: 0xF4 / 255) // Google blue
        case .copilot: Color(red: 0x89 / 255, green: 0x57 / 255, blue: 0xE5 / 255) // GitHub purple
        case .antigravity: Color(red: 0x31 / 255, green: 0x86 / 255, blue: 0xFF / 255) // Google Antigravity blue
        case .opencode,
             .cursor,
             .grok,
             .pi: .primary
        }
    }
}

private struct SidebarRowIcon: View {
    let symbol: String
    let index: Int
    var agent: AgentIcon?
    @AppStorage(Preferences.Keys.sidebarIconSize)
    private var iconSizeRaw = SidebarIconSize.medium.rawValue
    /// Scales with the user's text size like the sibling SF Symbols do; a
    /// fixed 15pt would stay small next to enlarged row text.
    @ScaledMetric(relativeTo: .body)
    private var agentIconSize: CGFloat = 15

    private var size: SidebarIconSize {
        SidebarIconSize(rawValue: iconSizeRaw) ?? .medium
    }

    var body: some View {
        if let agent {
            // A live AI agent in the tab overrides the user's chosen icon —
            // the logo is a status signal, tinted with the agent's brand color
            // (overriding the row's .secondary tint).
            let side = agentIconSize * size.glyphScale
            Image(agent.rawValue)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: side, height: side)
                .foregroundStyle(agent.brandColor)
        } else if Preferences.numberIconChoices.contains(symbol) {
            NumberGlyph(index: index, variant: symbol, size: size)
        } else {
            Image(systemName: symbol)
                .imageScale(size.imageScale)
        }
    }
}

private extension SidebarIconSize {
    /// SwiftUI's own symbol scaling, which sizes a symbol against whatever font
    /// the row hands it. `medium` is the default, so the middle case leaves an
    /// icon exactly the size it was before this preference existed rather than
    /// pinning it to a point size of our own.
    var imageScale: Image.Scale {
        switch self {
        case .small: .small
        case .medium: .medium
        case .large: .large
        }
    }
}

private struct NumberGlyph: View {
    let index: Int
    let variant: String
    var size: SidebarIconSize = .medium
    /// The `.body` point size, as a metric so the digits keep tracking the
    /// user's text size once `glyphScale` has been applied — `imageScale` is
    /// no help here, since these variants draw text rather than a symbol.
    @ScaledMetric(relativeTo: .body)
    private var bodyFontSize: CGFloat = 13

    private var digitFont: Font {
        .system(size: bodyFontSize * size.glyphScale).monospacedDigit()
    }

    var body: some View {
        if variant == Preferences.numberIconPlain {
            Text("\(index)")
                .font(digitFont)
        } else if let suffix = shapeSuffix, (1 ... 50).contains(index) {
            // SF Symbols ships `1.<shape>` through `50.<shape>`; beyond that,
            // fall back to plain digits so we don't render a missing glyph.
            Image(systemName: "\(index).\(suffix)")
                .imageScale(size.imageScale)
        } else {
            Text("\(index)")
                .font(digitFont)
        }
    }

    /// Maps the sentinel token (e.g. `number.circle.fill`) to the suffix used
    /// by the indexed SF Symbol (e.g. `circle.fill` in `1.circle.fill`).
    private var shapeSuffix: String? {
        switch variant {
        case Preferences.numberIconCircleFill: "circle.fill"
        case Preferences.numberIconCircle: "circle"
        case Preferences.numberIconSquareFill: "square.fill"
        case Preferences.numberIconSquare: "square"
        default: nil
        }
    }
}
