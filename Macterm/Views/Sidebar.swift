import SwiftUI
import UniformTypeIdentifiers

private enum SidebarItem: Hashable {
    case project(UUID)
    case tab(projectID: UUID, tabID: UUID)
}

/// A sidebar row's content region extends past the selection highlight's
/// trailing edge. A short label never reaches out there, but content that
/// fills the row — split segments, the merge drop slot, a fading title —
/// does, and reads as overflowing the highlight. Every row applies this
/// trailing inset at its root so all of them stop at the same edge.
private let rowTrailingInset: CGFloat = 10

/// Keeps the sidebar footer above scrolling rows, using the native macOS 26
/// scroll-edge fade when available.
private extension View {
    @ViewBuilder
    func sidebarSafeAreaBar(
        isPresented: Bool,
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
                        .background(MactermTheme.bg)
                }
            }
        } else {
            self
        }
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

/// The narrower union the pin drop zone accepts: a tab (pin/move) or a pane
/// (separate into a new pinned tab). Deliberately NOT `SidebarDropItem` — a
/// project drag has no meaning at the pin strip. (The tab lists themselves
/// use `DropDelegate`s + the insertion placeholder, not this payload — see
/// `SidebarRowDropDelegate`.)
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
    @State
    private var expandedProjects: Set<UUID> = []
    /// A Set (not a lone optional) so the sidebar supports native multi-select:
    /// Cmd/Shift-click extends the selection, and a right-click acts on every
    /// selected row at once (see `.contextMenu(forSelectionType:)` below).
    @State
    private var selection: Set<SidebarItem> = []
    /// The live insertion target while a drag hovers a pinned row — which row,
    /// and whether the payload would land above or below it (decided by which
    /// half of the row the pointer is in). Owns the insertion-placeholder
    /// lifecycle (see `SidebarDropCoordinator`).
    @State
    private var dropCoordinator = SidebarDropCoordinator()
    /// Each row's measured height, for the delegates' above/below midpoint
    /// test (`DropInfo.location` is in the row's own space) and for sizing
    /// the placeholder like a real row.
    @State
    private var sidebarRowHeights: [UUID: CGFloat] = [:]

    var body: some View {
        List(selection: $selection) {
            // Pinned tabs live above every project as FLAT top-level rows —
            // no enclosing section. Their ForEach carries NO
            // `.dropDestination`: at this outline level the accept crashes
            // (see the project ForEach's notes below), so each ROW hosts its
            // own drop delegate — and a hovering drag inserts a PLACEHOLDER
            // row at the slot the drop would land in, pushing the rows apart
            // to preview the final position (see `SidebarDropCoordinator`).
            // The always-available target — and the ONLY one when no pinned
            // rows exist yet — is the pin drop zone strip above the list
            // (see `PinTabDropZone`).
            ForEach(Array(appState.pinnedRecords.enumerated()), id: \.element.id) { index, record in
                insertionPlaceholder(for: .pinned(slot: index))
                pinnedRow(record: record, index: index)
            }
            insertionPlaceholder(for: .pinned(slot: appState.pinnedRecords.count))
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
        // The pin drop zone: a thin strip above the list that expands into a
        // visible "Pin Tab" band while a tab/pane drag hovers it. It lives
        // OUTSIDE the List on purpose — a plain view's `.dropDestination` has
        // none of the outline view's drop hazards (see the notes inside the
        // List body), and it exists even with zero pinned rows, so the FIRST
        // pin can be a drag too.
        .safeAreaInset(edge: .top, spacing: 0) {
            PinTabDropZone(
                onPinTab: { movable in
                    if movable.sourceProjectID == PinnedTabs.projectID {
                        // Already pinned — dropping on the top zone moves it
                        // to the first slot.
                        appState.reorderPinnedTab(movable.tabID, toIndex: 0)
                    } else {
                        appState.pinTab(movable.tabID, fromProject: movable.sourceProjectID, toRecordIndex: 0)
                    }
                },
                onPinPane: { movable in
                    appState.separatePane(
                        movable.paneID,
                        toProject: PinnedTabs.projectID,
                        destPath: PinnedTabs.fallbackRoot,
                        at: 0
                    )
                }
            )
        }
        .sidebarSafeAreaBar(isPresented: showNewProjectButton) {
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
        .onChange(of: selection) { _, items in
            // Navigation follows a single selection only. A multi-selection is
            // for bulk actions (delete), so it must not yank the active project
            // or tab around as rows are added to the selection.
            guard items.count == 1, let item = items.first else { return }
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
                expandedProjects.insert(newID)
            }
            syncSelection()
        }
        .onChange(of: activeTabID) {
            syncSelection()
        }
        .onAppear {
            if let id = appState.activeProjectID { expandedProjects.insert(id) }
            syncSelection()
        }
    }

    // MARK: - Pinned rows

    /// The insertion placeholder rendered at `insertion`'s slot while a drag
    /// targets it — a row-sized labeled box that pushes its neighbors apart
    /// to preview exactly where the drop will land. It is itself a drop
    /// target: the reflow that inserts it usually leaves the pointer ON it,
    /// so it must keep the proposal alive and accept the drop.
    @ViewBuilder
    private func insertionPlaceholder(for insertion: SidebarInsertion) -> some View {
        if dropCoordinator.insertion == insertion {
            let icon = switch insertion {
            case .pinned: "pin.fill"
            case .projectTab: "arrow.forward"
            }
            SidebarInsertionPlaceholder(
                label: dropCoordinator.label,
                icon: icon,
                height: sidebarRowHeights.values.max() ?? 24
            )
            .onDrop(
                of: [.mactermTab, .mactermPaneID],
                delegate: SidebarPlaceholderDropDelegate(
                    insertion: insertion,
                    coordinator: dropCoordinator,
                    perform: { performSidebarDrop($0, info: $1) }
                )
            )
        }
    }

    /// One pinned row: loaded (a live tab, standard row treatment with a pin
    /// icon) or unloaded (dimmed; selecting it rebuilds the tab from its
    /// declaration). Rows are top-level List items, so — unlike project tab
    /// rows before this interaction — each hosts its own drop delegate: there
    /// is no ForEach insertion mechanism at this outline level (a top-level
    /// `.dropDestination` crashes the outline accept, see `body`). A
    /// `DropDelegate`, not `.dropDestination`, because only the delegate
    /// reports the hover LOCATION — which half of the row the drag is over
    /// decides the placeholder's slot.
    private func pinnedRow(record: PinnedTabRecord, index: Int) -> some View {
        Group {
            if let tab = appState.pinnedWorkspace?.tabs.first(where: { $0.id == record.id }) {
                PinnedSidebarTabRow(
                    tab: tab,
                    onRename: { newName in
                        tab.customTitle = newName.isEmpty ? nil : newName
                        appState.saveWorkspaces()
                    }
                )
            } else {
                // Unloaded: the sessions died. The row stays (a pinned tab
                // can't be closed); selecting it restores from the layout.
                Label {
                    FadingText(record.displayTitle)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "pin.slash")
                        .foregroundStyle(.tertiary)
                }
                .help("Not running — select to restore from its saved layout")
            }
        }
        .padding(.trailing, rowTrailingInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .tag(SidebarItem.tab(projectID: PinnedTabs.projectID, tabID: record.id))
        // Dragging a pinned row into a project unpins it (AppState.moveTab
        // routes the record bookkeeping).
        .draggable(MovableTab(tabID: record.id, sourceProjectID: PinnedTabs.projectID))
        // The drop capture lives BEHIND the row, never on it — the
        // SplitLeafView pattern. An `.onDrop` directly on the row swallowed
        // left clicks (the row dragged fine but stopped being selectable);
        // a background destination still receives every drag, because drop
        // routing is geometric and only registered destinations participate,
        // while clicks pass through to the row and the List's selection.
        .background {
            Color.clear
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    sidebarRowHeights[record.id] = height
                }
                .onDrop(
                    of: [.mactermTab, .mactermPaneID],
                    delegate: SidebarRowDropDelegate(
                        index: index,
                        makeInsertion: { .pinned(slot: $0) },
                        rowHeight: { sidebarRowHeights[record.id] ?? 24 },
                        coordinator: dropCoordinator,
                        perform: { performSidebarDrop($0, info: $1) }
                    )
                )
        }
    }

    /// Apply a resolved sidebar drop at an insertion slot (record/tab-space
    /// insertion offset, pre-removal coordinates). A pane drag first — its
    /// payload is synchronously readable, same as `LeafDropDelegate` — then a
    /// tab drag, with the async item-provider fallback for a payload the
    /// Transferable hasn't rendered onto the pasteboard yet.
    @MainActor
    private func performSidebarDrop(_ insertion: SidebarInsertion, info: DropInfo) -> Bool {
        if let movable = MovablePane.fromDragPasteboard() {
            switch insertion {
            case let .pinned(slot):
                appState.separatePane(
                    movable.paneID,
                    toProject: PinnedTabs.projectID,
                    destPath: PinnedTabs.fallbackRoot,
                    at: slot
                )
            case let .projectTab(projectID, slot):
                guard let project = projectStore.projects.first(where: { $0.id == projectID }) else { return false }
                appState.separatePane(movable.paneID, toProject: projectID, destPath: project.path, at: slot)
            }
            return true
        }
        if let movable = MovableTab.fromDragPasteboard() {
            applyTabDrop(movable, insertion: insertion)
            return true
        }
        guard let provider = info.itemProviders(for: [.mactermTab]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.mactermTab.identifier) { data, _ in
            guard let data, let movable = try? JSONDecoder().decode(MovableTab.self, from: data) else { return }
            Task { @MainActor in
                applyTabDrop(movable, insertion: insertion)
            }
        }
        return true
    }

    /// A tab dropped at an insertion slot: reorder within its own list, pin
    /// into the pinned rows, or move across projects — all speaking the same
    /// pre-removal offsets (`reorderPinnedTab` / `reorderTab` / `moveTab`).
    @MainActor
    private func applyTabDrop(_ item: MovableTab, insertion: SidebarInsertion) {
        switch insertion {
        case let .pinned(slot):
            if item.sourceProjectID == PinnedTabs.projectID {
                appState.reorderPinnedTab(item.tabID, toIndex: slot)
            } else {
                appState.pinTab(item.tabID, fromProject: item.sourceProjectID, toRecordIndex: slot)
            }
        case let .projectTab(projectID, slot):
            if item.sourceProjectID == projectID {
                appState.reorderTab(item.tabID, inProject: projectID, toIndex: slot)
            } else {
                guard let project = projectStore.projects.first(where: { $0.id == projectID }) else { return }
                appState.moveTab(item.tabID, from: item.sourceProjectID, to: projectID, destPath: project.path, toIndex: slot)
                expandedProjects.insert(projectID)
            }
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
            get: { expandedProjects.contains(project.id) },
            set: { if $0 { expandedProjects.insert(project.id) } else { expandedProjects.remove(project.id) } }
        )) {
            // One drop interaction for every case, shared with the pinned
            // rows: hovering a drag over a row's top/bottom half inserts the
            // placeholder at that slot — pushing the rows apart to preview
            // the final position — and the drop lands exactly there. A tab
            // from the same project reorders, one from another project (or
            // the pinned rows) moves in, and a PANE (the grab-handle drag
            // from the workspace) separates into a new tab at the slot. This
            // replaced the ForEach-level `.dropDestination` (the native
            // insertion line): a hairline between rows couldn't say what the
            // drop would do, and it drew OVER the rows instead of making room.
            ForEach(Array(tabs.enumerated()), id: \.element.id) { tabIndex, tab in
                insertionPlaceholder(for: .projectTab(projectID: project.id, slot: tabIndex))
                tabRow(tab: tab, index: tabIndex, project: project)
            }
            insertionPlaceholder(for: .projectTab(projectID: project.id, slot: tabs.count))
        } label: {
            projectHeader(index: projectIndex, project: project)
        }
    }

    private func tabRow(tab: TerminalTab, index tabIndex: Int, project: Project) -> some View {
        SidebarTabRow(
            tab: tab,
            index: tabIndex + 1,
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
        // Drag a tab out to another project (or reorder within this one). The
        // payload is just IDs — the live tab is looked up on drop, never
        // serialized.
        .draggable(MovableTab(tabID: tab.id, sourceProjectID: project.id))
        // The drop capture lives BEHIND the row, never on it — an `.onDrop`
        // directly on a row swallows left clicks (measured on the pinned
        // rows: they dragged fine but stopped being selectable), while a
        // background destination still receives every drag, because drop
        // routing is geometric and only registered destinations participate.
        // Tab rows accept only tab/pane payloads, so a PROJECT drag over an
        // expanded section's tab rows still has nothing to land on — drop it
        // on a project header instead.
        .background {
            Color.clear
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    sidebarRowHeights[tab.id] = height
                }
                .onDrop(
                    of: [.mactermTab, .mactermPaneID],
                    delegate: SidebarRowDropDelegate(
                        index: tabIndex,
                        makeInsertion: { .projectTab(projectID: project.id, slot: $0) },
                        rowHeight: { sidebarRowHeights[tab.id] ?? 24 },
                        coordinator: dropCoordinator,
                        perform: { performSidebarDrop($0, info: $1) }
                    )
                )
        }
    }

    private func projectHeader(index projectIndex: Int, project: Project) -> some View {
        SidebarProjectRow(project: project, index: projectIndex + 1) {
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
            if targeted { expandedProjects.insert(project.id) }
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
        expandedProjects.insert(project.id)
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
        expandedProjects.insert(project.id)
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
            selection = appState.activeProjectID.map { [.project($0)] } ?? []
            return
        }
        let desired: Set<SidebarItem> = [.tab(projectID: pid, tabID: tabID)]
        if selection != desired { selection = desired }
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
            expandedProjects.insert(project.id)
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(project.path, forType: .string)
        }
        Divider()
        Button("Rename Project") { appState.renamingProjectID = project.id }
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

    /// A pinned row's menu. No Close — a pinned tab can't be closed; Unpin
    /// is the way out (a move for a loaded tab, a forget for an unloaded
    /// record).
    @ViewBuilder
    private func pinnedTabMenu(record: PinnedTabRecord) -> some View {
        let isLoaded = appState.isPinnedTabLoaded(record.id)
        if isLoaded {
            Button("Rename Tab") { appState.renamingTabID = record.id }
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
                        expandedProjects.insert(destination.id)
                    }
                }
            }
        }
        Divider()
        Button(isLoaded ? "Unpin Tab" : "Remove from Pinned", role: isLoaded ? nil : .destructive) {
            appState.unpinTab(record.id, projects: projectStore.projects)
        }
        if isLoaded {
            // Close = UNLOAD for a pinned tab: processes end, the dimmed row
            // stays, and the next launch starts it again. Unpin above is the
            // removal path.
            Button("Close Tab", role: .destructive) {
                appState.requestCloseTab(record.id, projectID: PinnedTabs.projectID)
            }
        }
    }

    @ViewBuilder
    private func tabMenu(project: Project, tab: TerminalTab) -> some View {
        Button("Rename Tab") { appState.renamingTabID = tab.id }
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
                        expandedProjects.insert(destination.id)
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
        expandedProjects.remove(project.id)
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
            case .tab(PinnedTabs.projectID, _):
                // Pinned tabs can't be closed — a bulk delete skips them.
                break
            case let .tab(projectID, tabID):
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
            selection = []
        }
    }

    private func openProject() {
        if let project = appState.openProject(store: projectStore) {
            expandedProjects.insert(project.id)
        }
    }
}

private struct SidebarProjectRow: View {
    let project: Project
    let index: Int
    let onRename: (String) -> Void
    @Environment(AppState.self)
    private var appState
    @AppStorage(Preferences.Keys.projectIconSymbol)
    private var projectIconSymbol = "folder"
    @State
    private var isRenaming = false
    @State
    private var renameText = ""
    @FocusState
    private var focused: Bool

    @ViewBuilder
    private var titleContent: some View {
        if isRenaming {
            TextField("", text: $renameText)
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
        appState.renamingProjectID = nil
        renameText = project.name
        isRenaming = true
    }

    private func commit() {
        let text = renameText.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { onRename(text) }
        isRenaming = false
        appState.restoreFocusToActivePane()
    }

    private func cancelRename() {
        isRenaming = false
        appState.restoreFocusToActivePane()
    }
}

private struct SidebarTabRow: View {
    let tab: TerminalTab
    let index: Int
    let onRename: (String) -> Void
    @Environment(AppState.self)
    private var appState
    @AppStorage(Preferences.Keys.tabIconSymbol)
    private var tabIconSymbol = "terminal"
    @AppStorage(Preferences.Keys.showAgentIcons)
    private var showAgentIcons = true
    @AppStorage(Preferences.Keys.showTabStatusIndicator)
    private var showTabStatusIndicator = false
    @State
    private var isRenaming = false
    @State
    private var renameText = ""
    @State
    private var preEditCustomTitle: String?
    @FocusState
    private var focused: Bool

    @ViewBuilder
    private var titleContent: some View {
        if isRenaming {
            TextField(tab.autoTitle, text: $renameText)
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

    var body: some View {
        Group {
            if tabIconSymbol == Preferences.noIcon {
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
                        TabStatusGlyph(state: tab.executionState, symbol: tabIconSymbol, index: index, agent: agentIcon)
                    } else if let agentIcon {
                        // "None" suppresses the user's icon, not the agent
                        // logo — a live status signal, like the else branch.
                        SidebarRowIcon(symbol: tabIconSymbol, index: index, agent: agentIcon)
                            .foregroundStyle(.secondary)
                    }
                }
                .labelStyle(.titleAndIcon)
            } else {
                Label {
                    titleContent
                } icon: {
                    if showTabStatusIndicator {
                        TabStatusGlyph(state: tab.executionState, symbol: tabIconSymbol, index: index, agent: agentIcon)
                    } else {
                        SidebarRowIcon(symbol: tabIconSymbol, index: index, agent: agentIcon)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: appState.renamingTabID) { _, id in
            if id == tab.id { beginRename() }
        }
    }

    private func beginRename() {
        appState.renamingTabID = nil
        preEditCustomTitle = tab.customTitle
        renameText = tab.customTitle ?? ""
        isRenaming = true
    }

    private func commit() {
        let text = renameText.trimmingCharacters(in: .whitespaces)
        let newCustomTitle: String? = text.isEmpty ? nil : text
        if newCustomTitle != preEditCustomTitle {
            onRename(text)
        }
        isRenaming = false
        appState.restoreFocusToActivePane()
    }

    private func cancelRename() {
        isRenaming = false
        appState.restoreFocusToActivePane()
    }
}

/// Where a hovering drag would insert into the sidebar: a pinned-row slot or
/// a project's tab slot (record/tab-space insertion offsets, pre-removal
/// coordinates — the shape `reorderPinnedTab`/`reorderTab`/`moveTab` speak).
enum SidebarInsertion: Equatable {
    case pinned(slot: Int)
    case projectTab(projectID: UUID, slot: Int)
}

/// Owns the insertion placeholder's lifecycle. One coordinator for the whole
/// sidebar, because the placeholder is a single row that MOVES between slots
/// as the drag travels — and because clearing it is the subtle part:
///
/// - Inserting the placeholder reflows the rows UNDER the pointer, so the
///   row that proposed it usually fires `dropExited` immediately (the
///   placeholder took its place). Clearing on that exit would remove the
///   placeholder, reflow back, re-enter, and flicker forever — so an exit
///   only SCHEDULES a clear, and any proposal inside the grace period
///   (the take-over enter, the next row) cancels it.
/// - `dropExited` is not delivered reliably for a cancelled drag (Esc, or a
///   release outside every target), so while a placeholder is up a watchdog
///   polls the physical mouse button: the drag is over the moment it's
///   released. A completed drop clears immediately via `complete()`.
@MainActor @Observable
final class SidebarDropCoordinator {
    private(set) var insertion: SidebarInsertion?
    private(set) var label = ""

    @ObservationIgnored
    private var clearWork: DispatchWorkItem?
    @ObservationIgnored
    private var watchdog: Timer?

    func propose(_ insertion: SidebarInsertion, label: String) {
        clearWork?.cancel()
        clearWork = nil
        if self.insertion != insertion || self.label != label {
            withAnimation(.easeInOut(duration: 0.12)) {
                self.insertion = insertion
                self.label = label
            }
        }
        startWatchdogIfNeeded()
    }

    /// A target the drag left — see the flicker note above: schedule, don't
    /// clear.
    func noteExit() {
        guard insertion != nil else { return }
        clearWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.clearNow() }
        }
        clearWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// The drop landed (anywhere) — collapse immediately.
    func complete() {
        clearNow()
    }

    private func clearNow() {
        clearWork?.cancel()
        clearWork = nil
        watchdog?.invalidate()
        watchdog = nil
        guard insertion != nil else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            insertion = nil
            label = ""
        }
    }

    private func startWatchdogIfNeeded() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSEvent.pressedMouseButtons & 0x1 == 0 { self.clearNow() }
            }
        }
        // .common so it keeps firing inside the drag's event-tracking run
        // loop mode.
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }
}

/// What the hovered drop would do, for the placeholder's label. The payload
/// is synchronously readable off the drag pasteboard for in-app drags (falls
/// open to the pin/move default when it isn't rendered yet).
private func sidebarDragActionLabel(for insertion: SidebarInsertion) -> String {
    if MovablePane.fromDragPasteboard() != nil {
        return switch insertion {
        case .pinned: "Pin Pane"
        case .projectTab: "Move Pane"
        }
    }
    let source = MovableTab.fromDragPasteboard()?.sourceProjectID
    return switch insertion {
    case .pinned: source == PinnedTabs.projectID ? "Move Tab" : "Pin Tab"
    case .projectTab: "Move Tab"
    }
}

/// The per-row drop delegate shared by pinned rows and project tab rows. A
/// delegate (not `.dropDestination`) because only `DropInfo` carries the
/// hover location — which half of the row the drag is over decides whether
/// the placeholder lands above (`index`) or below (`index + 1`) the row.
private struct SidebarRowDropDelegate: DropDelegate {
    let index: Int
    let makeInsertion: (Int) -> SidebarInsertion
    let rowHeight: () -> CGFloat
    let coordinator: SidebarDropCoordinator
    let perform: @MainActor (SidebarInsertion, DropInfo) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.mactermTab, .mactermPaneID])
    }

    func dropEntered(info: DropInfo) {
        propose(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        propose(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        MainActor.assumeIsolated { coordinator.noteExit() }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            let insertion = resolvedInsertion(info)
            coordinator.complete()
            return perform(insertion, info)
        }
    }

    private func resolvedInsertion(_ info: DropInfo) -> SidebarInsertion {
        makeInsertion(info.location.y > rowHeight() / 2 ? index + 1 : index)
    }

    private func propose(_ info: DropInfo) {
        MainActor.assumeIsolated {
            let insertion = resolvedInsertion(info)
            coordinator.propose(insertion, label: sidebarDragActionLabel(for: insertion))
        }
    }
}

/// The placeholder row's own delegate: the reflow that inserts the
/// placeholder usually leaves the pointer ON it, so it must keep the
/// proposal alive (cancelling the exit-scheduled clear) and accept the drop
/// at its slot.
private struct SidebarPlaceholderDropDelegate: DropDelegate {
    let insertion: SidebarInsertion
    let coordinator: SidebarDropCoordinator
    let perform: @MainActor (SidebarInsertion, DropInfo) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.mactermTab, .mactermPaneID])
    }

    func dropEntered(info _: DropInfo) {
        propose()
    }

    func dropUpdated(info _: DropInfo) -> DropProposal? {
        propose()
        return DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        MainActor.assumeIsolated { coordinator.noteExit() }
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            coordinator.complete()
            return perform(insertion, info)
        }
    }

    private func propose() {
        MainActor.assumeIsolated {
            coordinator.propose(insertion, label: sidebarDragActionLabel(for: insertion))
        }
    }
}

/// The insertion placeholder: a row-sized labeled box occupying the slot the
/// drop would land in, pushing the real rows apart to preview the final
/// position — the same band style as `PinTabDropZone`.
private struct SidebarInsertionPlaceholder: View {
    let label: String
    let icon: String
    let height: CGFloat

    var body: some View {
        Label(label, systemImage: icon)
            .font(.callout.weight(.medium))
            .foregroundStyle(MactermTheme.accent)
            .frame(maxWidth: .infinity)
            .frame(height: max(height, 20))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(MactermTheme.accent.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(MactermTheme.accent.opacity(0.5), lineWidth: 1)
                    )
            )
            .padding(.trailing, 2)
    }
}

/// The pin drop zone at the top of the sidebar: a near-invisible strip that
/// expands into a labeled "Pin Tab" band while a tab or pane drag hovers it,
/// and pins the payload at the first slot on drop. The strip must keep a
/// nonzero idle height — `isTargeted` only fires once the pointer is over the
/// target, so a zero-height strip could never be discovered by a drag.
private struct PinTabDropZone: View {
    let onPinTab: (MovableTab) -> Void
    let onPinPane: (MovablePane) -> Void
    @State
    private var isTargeted = false

    var body: some View {
        ZStack {
            if isTargeted {
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
        .frame(height: isTargeted ? 38 : 12)
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

/// A LOADED pinned tab's row: `SidebarTabRow`'s behavior with the pin
/// as the row's fixed icon — pinned rows are top-level items with no project
/// section around them, so the pin is what says which rows these are. The
/// status glyph (spinner / done dot) and agent logo layer over it exactly
/// like a normal tab row's icon.
private struct PinnedSidebarTabRow: View {
    let tab: TerminalTab
    let onRename: (String) -> Void
    @Environment(AppState.self)
    private var appState
    @AppStorage(Preferences.Keys.showAgentIcons)
    private var showAgentIcons = true
    @AppStorage(Preferences.Keys.showTabStatusIndicator)
    private var showTabStatusIndicator = false
    @State
    private var isRenaming = false
    @State
    private var renameText = ""
    @State
    private var preEditCustomTitle: String?
    @FocusState
    private var focused: Bool

    private var agentIcon: AgentIcon? {
        showAgentIcons ? tab.agentIcon : nil
    }

    var body: some View {
        Label {
            if isRenaming {
                TextField(tab.autoTitle, text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { cancelRename() }
                    .onAppear { focused = true }
            } else {
                TabRowTitle(tab: tab)
            }
        } icon: {
            if showTabStatusIndicator {
                TabStatusGlyph(state: tab.executionState, symbol: "pin", index: 0, agent: agentIcon)
            } else {
                SidebarRowIcon(symbol: "pin", index: 0, agent: agentIcon)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: appState.renamingTabID) { _, id in
            if id == tab.id { beginRename() }
        }
    }

    private func beginRename() {
        appState.renamingTabID = nil
        preEditCustomTitle = tab.customTitle
        renameText = tab.customTitle ?? ""
        isRenaming = true
    }

    private func commit() {
        let text = renameText.trimmingCharacters(in: .whitespaces)
        let newCustomTitle: String? = text.isEmpty ? nil : text
        if newCustomTitle != preEditCustomTitle {
            onRename(text)
        }
        isRenaming = false
        appState.restoreFocusToActivePane()
    }

    private func cancelRename() {
        isRenaming = false
        appState.restoreFocusToActivePane()
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
///   Xcode-build-navigator style).
/// - `done` (needs attention): the icon with a small solid status dot in the
///   bottom-trailing corner — like the Messages/FaceTime "available" dot. A
///   dot reads as "done/positive" without competing with the icon's identity,
///   and it avoids the heavy, off-platform look of a checkmark glyph badge.
/// - `idle`: the icon as-is.
private struct TabStatusGlyph: View {
    let state: TerminalExecutionState
    let symbol: String
    let index: Int
    var agent: AgentIcon?

    var body: some View {
        switch state {
        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
                .help("Running")
                .frame(width: 16, height: 16)
        case .done:
            SidebarRowIcon(symbol: symbol, index: index, agent: agent)
                .foregroundStyle(.secondary)
                .overlay(alignment: .bottomTrailing) {
                    // Opaque (not translucent) so it reads clearly over the
                    // icon and the sidebar background. Nested in a background
                    // ring so it stays legible over any icon color.
                    Circle()
                        .fill(.background)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle()
                                .fill(MactermTheme.success)
                                .frame(width: 5, height: 5)
                        )
                        .offset(x: 2.5, y: 2.5)
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
    /// Scales with the user's text size like the sibling SF Symbols do; a
    /// fixed 15pt would stay small next to enlarged row text.
    @ScaledMetric(relativeTo: .body)
    private var agentIconSize: CGFloat = 15

    var body: some View {
        if let agent {
            // A live AI agent in the tab overrides the user's chosen icon —
            // the logo is a status signal, tinted with the agent's brand color
            // (overriding the row's .secondary tint).
            Image(agent.rawValue)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: agentIconSize, height: agentIconSize)
                .foregroundStyle(agent.brandColor)
        } else if Preferences.numberIconChoices.contains(symbol) {
            NumberGlyph(index: index, variant: symbol)
        } else {
            Image(systemName: symbol)
        }
    }
}

private struct NumberGlyph: View {
    let index: Int
    let variant: String

    var body: some View {
        if variant == Preferences.numberIconPlain {
            Text("\(index)")
                .font(.body.monospacedDigit())
        } else if let suffix = shapeSuffix, (1 ... 50).contains(index) {
            // SF Symbols ships `1.<shape>` through `50.<shape>`; beyond that,
            // fall back to plain digits so we don't render a missing glyph.
            Image(systemName: "\(index).\(suffix)")
        } else {
            Text("\(index)")
                .font(.body.monospacedDigit())
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
