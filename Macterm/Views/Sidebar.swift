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

/// The TITLE's coordinate space. Everything the join band needs — the seams
/// it draws on and the pointer positions it compares them against — is
/// measured here, so there is no conversion between two spaces to get wrong.
private let tabTitleSpace = "macterm.sidebar.tabTitle"

/// The width the title has to work with, which decides whether a split tab
/// shows its panes' names or falls back to counting them.
private struct TabTitleWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Where a split row actually drew its per-pane segments. The join indicator
/// has to sit on the divider the user is aiming at, and only the layout knows
/// where that ended up.
private struct TabSegmentFramesKey: PreferenceKey {
    static let defaultValue: [CGRect] = []

    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

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
    @State
    private var expandedProjects: Set<UUID> = []
    /// A Set (not a lone optional) so the sidebar supports native multi-select:
    /// Cmd/Shift-click extends the selection, and a right-click acts on every
    /// selected row at once (see `.contextMenu(forSelectionType:)` below).
    @State
    private var selection: Set<SidebarItem> = []

    var body: some View {
        List(selection: $selection) {
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
            case let .tab(projectID, tabID):
                if let project = projectStore.projects.first(where: { $0.id == projectID }) {
                    appState.selectProject(project)
                    appState.selectTab(tabID, projectID: projectID)
                }
            }
        }
        .onChange(of: appState.activeProjectID) { _, newID in
            if let newID { expandedProjects.insert(newID) }
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
    }

    private func tabRow(tab: TerminalTab, index tabIndex: Int, project: Project) -> some View {
        TabRow(
            tab: tab,
            index: tabIndex + 1,
            onRename: { newName in
                tab.customTitle = newName.isEmpty ? nil : newName
                appState.saveWorkspaces()
            },
            onMergeDrop: { item, insertionIndex in
                receiveMergeDrop(item, into: tab, project: project, at: insertionIndex)
            }
        )
        .tag(SidebarItem.tab(projectID: project.id, tabID: tab.id))
        // Drag a tab out to another project (or reorder within this one). The
        // payload is just IDs — the live tab is looked up on drop, never
        // serialized.
        .draggable(MovableTab(tabID: tab.id, sourceProjectID: project.id))
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

    /// Apply a drop on a tab row's merge band: the dragged pane (or the whole
    /// dragged tab) JOINS this tab's split tree — the inverse of dragging a
    /// pane out to the sidebar, and the gesture that puts two terminals back
    /// in one tab without aiming at the workspace.
    ///
    /// `insertionIndex` is the seam the pointer chose, so the drop decides the
    /// ORDER inside the tab too, not just which tab. A row whose panes have
    /// vanished mid-drag resolves to no target and the drop is dropped, rather
    /// than landing somewhere the user didn't point at.
    private func receiveMergeDrop(
        _ item: TabSlotDropItem,
        into tab: TerminalTab,
        project: Project,
        at insertionIndex: Int
    ) {
        guard let target = TabMergePlacement.target(
            insertionIndex: insertionIndex,
            panes: tab.splitRoot.allPanes().map(\.id)
        )
        else { return }
        switch item {
        case let .tab(dragged):
            appState.mergeTab(
                dragged.tabID,
                from: dragged.sourceProjectID,
                intoTab: tab.id,
                at: target,
                inProject: project.id
            )
        case let .pane(dragged):
            appState.mergePane(
                dragged.paneID,
                intoTab: tab.id,
                inProject: project.id,
                destPath: project.path,
                at: target
            )
        }
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
            case let .project(id):
                projectIDs.append(id)
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

/// One tab's row: the label, the seams its split segments were drawn at, and
/// the merge band that uses them.
///
/// A view rather than a function on `SidebarContent` because the seams are
/// measured state: the segments report their frames through a preference, and
/// the band needs them to draw the indicator on the divider rather than a few
/// points beside it.
private struct TabRow: View {
    let tab: TerminalTab
    let index: Int
    let onRename: (String) -> Void
    let onMergeDrop: @Sendable @MainActor (TabSlotDropItem, Int) -> Void

    var body: some View {
        // The join band lives INSIDE the row's title (see `SidebarTabRow`),
        // not as an overlay measured against the row. Two attempts to place it
        // by geometry both leaked: the tab's icon kept accepting drops, either
        // because the frame was measured in one space and the drop reported in
        // another, or because `.position` handed the whole row back as the
        // target. Making the title the band's parent removes the arithmetic —
        // the icon is outside it by construction.
        SidebarTabRow(tab: tab, index: index, onRename: onRename, onMergeDrop: onMergeDrop)
            .padding(.trailing, rowTrailingInset)
            // Stretch to the full row and make every point hit-testable:
            // without this, the drag grab area hugs the label's intrinsic
            // width instead of covering the whole row.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// The merge band across a tab row's middle: drop a pane (or another tab)
/// here and it joins THIS tab's split tree, at the position you aimed at.
///
/// Spanning the row's full width at its vertical CENTER is what gives a drag
/// three distinct meanings over one row — aim high (the seam under the row
/// above) to insert a new tab before this one, aim low (the seam over the row
/// below) to insert after, aim at the body to join. The height is a fraction
/// rather than an inset so those outer bands stay reachable at any row height:
/// they belong to the native insertion line, and a band that covered them
/// would claim the drag first and kill tab reordering (see `tabRow`).
///
/// The affordance is an insertion line, not a filled rectangle, because a
/// filled row can only say "it goes in here" — while a split tab's row draws
/// one segment per pane, and the seams between them are positions the user can
/// already see. A line at the nearest seam says WHERE among them it lands.
private struct TabMergeSlot: View {
    /// Share of the row height the join band takes, leaving a quarter of the
    /// row above and below it for the insertion line.
    private static let heightFraction: CGFloat = 0.5
    /// Never shrink below a band the pointer can actually land in.
    private static let minHeight: CGFloat = 10

    let paneIDs: [UUID]
    /// Where the row drew its segment dividers, empty when it drew none.
    let seams: [CGFloat]
    /// `@Sendable @MainActor` because the async payload fallback hands this to
    /// an item provider's completion, which runs off the main actor: a plain
    /// closure can't cross that boundary under Swift 6's isolation checking.
    let onDrop: @Sendable @MainActor (TabSlotDropItem, Int) -> Void

    /// Which seam the pointer is nearest, or nil when no drag is over the
    /// band. Doubles as the "is targeted" flag — there is no state where the
    /// line should draw without a position.
    @State
    private var insertionIndex: Int?

    var body: some View {
        GeometryReader { geo in
            let bandHeight = max(geo.size.height * Self.heightFraction, Self.minHeight)
            // A row that drew no dividers — a single-pane tab, or one
            // collapsed to a pane count — offers exactly one position, its
            // trailing edge: there is nothing visible to land BETWEEN, so the
            // only honest indicator is "after what is here".
            let positions = seams.isEmpty ? [geo.size.width] : seams
            ZStack(alignment: .topLeading) {
                // The band spans this view, which IS the title area — no
                // measuring, no coordinate conversion, and the pointer
                // positions the drop reports are already in the same space as
                // the seams.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: bandHeight)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .onDrop(
                        of: [.mactermPaneID, .mactermTab],
                        delegate: TabMergeDropDelegate(
                            positions: positions,
                            appendIndex: paneIDs.count,
                            hasSeams: !seams.isEmpty,
                            insertionIndex: $insertionIndex,
                            onDrop: onDrop
                        )
                    )

                if let insertionIndex {
                    InsertionLine(
                        x: positions[min(insertionIndex, positions.count - 1)],
                        height: geo.size.height
                    )
                    // Drawn over the whole row while the band that reads the
                    // drop stays the middle half, so the outer quarters keep
                    // belonging to the row-order insertion line even though
                    // this reaches them.
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

/// The join indicator: a vertical rule at the chosen seam, capped with a dot,
/// matching the shape of the insertion line the List draws between rows so the
/// two gestures read as one family — that one orders TABS, this one orders the
/// terminals inside a tab.
private struct InsertionLine: View {
    private static let lineWidth: CGFloat = 2
    private static let dotDiameter: CGFloat = 6

    let x: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(MactermTheme.accent)
                .frame(width: Self.lineWidth, height: height)
            Circle()
                .fill(MactermTheme.accent)
                .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                .offset(y: -Self.dotDiameter / 3)
        }
        // Half the line width in from either end, so a seam at the row's edge
        // draws fully inside it rather than half-clipped.
        .position(x: max(x, Self.lineWidth / 2), y: height / 2)
        .animation(.easeInOut(duration: 0.08), value: x)
    }
}

/// A raw `DropDelegate` rather than `.dropDestination(for:)`, for one reason:
/// the Transferable form reports no pointer location, and the position within
/// the row IS the choice being made here. Payloads are therefore decoded the
/// same way the workspace leaves decode them.
private struct TabMergeDropDelegate: DropDelegate {
    /// The x positions the indicator can occupy — the row's real dividers, or
    /// a single trailing edge when it drew none.
    let positions: [CGFloat]
    /// The index a position-less row resolves to: append after every pane.
    let appendIndex: Int
    let hasSeams: Bool
    let insertionIndex: Binding<Int?>
    let onDrop: @Sendable @MainActor (TabSlotDropItem, Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.mactermPaneID, .mactermTab])
    }

    func dropEntered(info: DropInfo) {
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // `dropUpdated` fires again AFTER `performDrop`, and updating there
        // re-showed the indicator on a completed drop and left it stuck on the
        // row — the same trap `LeafDropDelegate` documents. Only a drag that
        // is still in flight (entered, not yet dropped) has a position.
        guard insertionIndex.wrappedValue != nil else { return DropProposal(operation: .forbidden) }
        update(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        insertionIndex.wrappedValue = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let index = resolvedIndex(at: info.location.x)
        insertionIndex.wrappedValue = nil

        // A pane's bytes are usually already on the drag pasteboard (the grab
        // handle writes them eagerly); a sidebar segment's arrive through the
        // item provider, so both reads exist here as they do on the leaves.
        if let movable = MovablePane.fromDragPasteboard() {
            let drop = onDrop
            MainActor.assumeIsolated { drop(.pane(movable), index) }
            return true
        }
        if let movable = MovableTab.fromDragPasteboard() {
            let drop = onDrop
            MainActor.assumeIsolated { drop(.tab(movable), index) }
            return true
        }
        return loadAsync(info: info, index: index)
    }

    private func loadAsync(info: DropInfo, index: Int) -> Bool {
        let drop = onDrop
        if let provider = info.itemProviders(for: [.mactermPaneID]).first {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.mactermPaneID.identifier) { data, _ in
                guard let data, let movable = MovablePane(payload: data) else { return }
                Task { @MainActor in
                    drop(.pane(movable), index)
                }
            }
            return true
        }
        guard let provider = info.itemProviders(for: [.mactermTab]).first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: UTType.mactermTab.identifier) { data, _ in
            guard let data, let movable = try? JSONDecoder().decode(MovableTab.self, from: data) else { return }
            Task { @MainActor in
                drop(.tab(movable), index)
            }
        }
        return true
    }

    private func update(_ info: DropInfo) {
        insertionIndex.wrappedValue = resolvedIndex(at: info.location.x)
    }

    /// Seam index for a pointer position — or the append slot for a row with
    /// no dividers, where the single drawn position means "after everything"
    /// regardless of how many panes are behind it.
    private func resolvedIndex(at x: CGFloat) -> Int {
        guard hasSeams else { return appendIndex }
        return TabMergePlacement.insertionIndex(x: x, seams: positions)
    }
}

private struct SidebarTabRow: View {
    let tab: TerminalTab
    let index: Int
    let onRename: (String) -> Void
    let onMergeDrop: @Sendable @MainActor (TabSlotDropItem, Int) -> Void

    /// Where this row drew its segment dividers, in the title's own space.
    @State
    private var seams: [CGFloat] = []

    /// The title's width, for deciding how many names fit.
    @State
    private var titleWidth: CGFloat = 0

    /// Room a segment needs before its title is worth showing. Tuned on
    /// screen: 44pt held names back while they were still perfectly readable,
    /// and the fading titles degrade gracefully — a clipped `nvi…` still says
    /// more than a pane count does.
    private static let minSegmentWidth: CGFloat = 32

    /// Show one title per pane while they still fit, and count them when they
    /// don't. The old rule was a fixed "2 or 3 panes", which is the same
    /// judgement made once for a sidebar that can be dragged from 140pt to
    /// 280pt: at its widest four names fit comfortably, at its narrowest even
    /// two are cramped. A user-set title always wins — the user named the
    /// whole tab, so the tab is what the row should say.
    private var showsSegments: Bool {
        let panes = tab.splitRoot.allPanes().count
        guard tab.customTitle == nil, panes >= 2 else { return false }
        return titleWidth >= CGFloat(panes) * Self.minSegmentWidth
    }

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

    /// The title, and over it the band that joins terminals into this tab.
    ///
    /// The band is a child of the TITLE rather than an overlay on the row,
    /// because the title is exactly the region it should cover: the tab's icon
    /// names the whole tab and is where the row's own drag lifts from, so it
    /// must not offer a position among the panes. Two attempts to achieve that
    /// by measuring frames both leaked the icon back in — one of them because
    /// the measurement landed on the PROJECT row's title, which has the same
    /// shape. Parenting removes the arithmetic and the ambiguity.
    ///
    /// Expanding to the full width keeps the target usable: a single-pane
    /// row's title is only as wide as the word in it, and a band that narrow
    /// made joining two single-pane tabs impossible.
    private var titleContent: some View {
        rawTitle
            .frame(maxWidth: .infinity, alignment: .leading)
            .coordinateSpace(name: tabTitleSpace)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: TabTitleWidthKey.self, value: proxy.size.width)
                }
            }
            .onPreferenceChange(TabTitleWidthKey.self) { width in
                titleWidth = width
            }
            .onPreferenceChange(TabSegmentFramesKey.self) { frames in
                seams = TabMergePlacement.seams(segmentFrames: frames)
            }
            .overlay {
                TabMergeSlot(
                    paneIDs: tab.splitRoot.allPanes().map(\.id),
                    seams: seams,
                    onDrop: onMergeDrop
                )
            }
    }

    @ViewBuilder
    private var rawTitle: some View {
        if isRenaming {
            TextField(tab.autoTitle, text: $renameText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { cancelRename() }
                .onAppear { focused = true }
        } else if showsSegments {
            // #227: a split tab reads as multiple tabs sharing one row — one
            // chromeless title segment per pane instead of one tab
            // concatenating the titles with a pipe. Whether they fit is
            // measured rather than assumed (see `showsSegments`); when they
            // don't, the row collapses to the pane count (see
            // `sidebarRowTitle`). The segments are a TITLE variant, not their
            // own labels: the row carries one tab icon regardless of how it is
            // named.
            splitSegments
        } else {
            FadingText(tab.sidebarRowTitle)
        }
    }

    /// The tab's live agent logo, unless disabled in Settings.
    private var agentIcon: AgentIcon? {
        showAgentIcons ? tab.agentIcon : nil
    }

    /// One title segment per pane, sharing the row in equal widths, divided
    /// by hairlines so adjacent titles don't read as one run-on name.
    ///
    /// Each segment carries its OWN drag, of that single pane. A split tab
    /// reads as several terminals sharing a row, so dragging the one you
    /// pointed at should move that one — dragging the row moves the whole tab,
    /// which is the segment-less behavior and stays available on the icon and
    /// the padding around the segments.
    private var splitSegments: some View {
        HStack(spacing: 10) {
            ForEach(Array(tab.splitRoot.allPanes().enumerated()), id: \.element.id) { i, pane in
                if i > 0 { Divider() }
                FadingText(pane.sidebarSegmentTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Hit-testable across the whole segment, not just the
                    // glyphs: a short title would otherwise leave most of its
                    // share of the row dragging the tab instead.
                    .contentShape(Rectangle())
                    .draggable(MovablePane(paneID: pane.id))
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: TabSegmentFramesKey.self,
                                value: [proxy.frame(in: .named(tabTitleSpace))]
                            )
                        }
                    }
            }
        }
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
