import AppKit
import SwiftUI

/// Projects settings: the runtime project list and the layout files on disk,
/// each manageable without touching a file or the CLI.
///
/// The two lists are deliberately separate because the model is: `projects.json`
/// owns which projects exist, and `~/.config/macterm/projects/*.yaml` owns their
/// declared layouts — matched by path, not identity. A layout file can exist
/// with no project backing it (hand-authored, or left behind by a removed
/// project); those orphans are invisible anywhere else in the UI, so the
/// Layouts list shows every file and offers to turn one into a project.
struct ProjectsSettings: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore

    /// Layout files, re-read on appear and after every mutation. There's no
    /// file watcher anywhere in the app by design (hand-edits surface on next
    /// use), so this mirrors that: a snapshot, refreshed at the points where
    /// the user can expect it to change.
    @State private var layouts: [ProjectFileStore.Listing] = []
    @State private var layoutPendingDeletion: ProjectFileStore.Listing?
    /// The zmx install sheet for a remote project (#699), on this window:
    /// the main window's copy would open behind Settings.
    @State private var zmxInstall: ZmxInstallRequest?
    @State private var deleteFailure: String?

    var body: some View {
        Form {
            Section {
                if projectStore.projects.isEmpty {
                    Text("No projects.")
                        .foregroundStyle(.secondary)
                } else {
                    // Rows go straight into the section — the same shape the
                    // Keymaps pane uses. A nested `List` here needed a fixed
                    // height, which capped the pane at ~6 projects: the Form's
                    // scroll view swallows the inner one's wheel events, so
                    // anything past the cap was unreachable. Plain rows grow
                    // with the content and let the Form scroll, which is the
                    // only scroll view in the pane that works.
                    //
                    // The cost is `.onMove`, which exists only on `List`, so
                    // reordering moved into the row menu.
                    ForEach(Array(projectStore.projects.enumerated()), id: \.element.id) { index, project in
                        projectRow(project, at: index)
                    }
                }
                Text("Change the order in the menu of a row. The order is the same as in the sidebar.")
                    .settingsSecondaryText()
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    // The same two creation paths the sidebar offers, so a
                    // project can be added without leaving Settings.
                    Menu {
                        Button("Local Folder…") { addLocalProject() }
                        Button("Remote Machine…") { addRemoteProject() }
                    } label: {
                        Label("Add Project", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add a project")
                }
            }

            Section {
                if layouts.isEmpty {
                    Text("No layout files.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(layouts) { layout in
                        LayoutRow(
                            layout: layout,
                            hasProject: hasProject(for: layout),
                            onCreateProject: { createProject(from: layout) },
                            onRemove: { layoutPendingDeletion = layout }
                        )
                    }
                }
                LabeledContent("Folder") {
                    Button(ProjectFileStore.defaultDirectory().path(percentEncoded: false)) {
                        revealLayoutFolder()
                    }
                    .buttonStyle(.link)
                    .linkPointer()
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Text("Removing a layout deletes its file. The project stays.")
                    .settingsSecondaryText()
            } header: {
                DocsSectionHeader("Layouts", docs: .layouts)
            }
        }
        .formStyle(.grouped)
        .onAppear { reloadLayouts() }
        .sheet(item: $zmxInstall) { request in
            ZmxInstallSheet(request: request) { installed in
                guard let projectID = request.projectID else { return }
                appState.useInstalledZmx(at: installed, for: projectID, store: projectStore)
            }
        }
        // Reflect a Save Layout made from this pane (or elsewhere while it's
        // open) — a save can create a file the list doesn't know about yet.
        .onChange(of: appState.layoutFilesVersion) { _, _ in reloadLayouts() }
        .alert(
            "Remove layout file?",
            isPresented: Binding(
                get: { layoutPendingDeletion != nil },
                set: { if !$0 { layoutPendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { layoutPendingDeletion = nil }
                .keyboardShortcut(.cancelAction)
            Button("Remove", role: .destructive) { confirmDeletion() }
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("""
            Macterm deletes “\(layoutPendingDeletion?.filename ?? "")”. The projects that use it stay, \
            but they lose their saved layout.
            """)
        }
        .alert(
            "Cannot remove the layout file",
            isPresented: Binding(
                get: { deleteFailure != nil },
                set: { if !$0 { deleteFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) { deleteFailure = nil }
        } message: {
            Text(deleteFailure ?? "")
        }
    }

    // MARK: - Projects

    /// One row. A function, not an inline expression: with the closures
    /// written out in the `ForEach`, the type-checker gave up on the body.
    private func projectRow(_ project: Project, at index: Int) -> some View {
        ProjectRow(
            project: project,
            canMoveUp: index > 0,
            canMoveDown: index < projectStore.projects.count - 1,
            onMoveUp: { projectStore.reorder(fromOffsets: [index], toOffset: index - 1) },
            onMoveDown: { projectStore.reorder(fromOffsets: [index], toOffset: index + 2) },
            onInstallZmx: { installZmx(on: project) }
        )
    }

    private func installZmx(on project: Project) {
        zmxInstall = ZmxInstallRequest(path: project.path, projectID: project.id, zmxPath: project.zmxPath)
    }

    /// Folder picker → new project → select it, the same as the sidebar's
    /// "Local Folder…". Picking a directory that already backs a project makes
    /// a second, independent one (a directory is not an identity).
    private func addLocalProject() {
        appState.openProject(store: projectStore)
    }

    /// The remote sheet is attached to `MainWindow`, so it would open behind the
    /// settings window. Front the terminal window first — the sheet is where the
    /// host/dir get entered, and it has to be visible to be filled in.
    private func addRemoteProject() {
        for window in NSApp.windows where window.isVisible && !(window is NSPanel) {
            guard window.contentViewController != nil, window.canBecomeMain else { continue }
            window.makeKeyAndOrderFront(nil)
            break
        }
        appState.isNewRemoteProjectSheetPresented = true
    }

    // MARK: - Layouts

    private func reloadLayouts() {
        layouts = appState.projectFiles.listAll()
    }

    /// Whether some project in the list already backs this file's declared
    /// path. Drives the muted "Create Project" affordance: creating a second
    /// project for a path is legal (a directory is not an identity), but for a
    /// file that already has one it's rarely what's wanted, so it's labeled.
    private func hasProject(for layout: ProjectFileStore.Listing) -> Bool {
        guard let declared = layout.declaredPath else { return false }
        return projectStore.projects.contains { ProjectPath.matches($0.path, declared) }
    }

    /// Add a project for this file's declaration and select it. The new
    /// project opens with the default workspace; the file's layout takes
    /// effect through Apply Layout (the row menu beside it), never on
    /// selection.
    private func createProject(from layout: ProjectFileStore.Listing) {
        guard let path = layout.declaredPath else { return }
        // `name:` is optional in a project file; fall back to the filename,
        // which is the slug of a name Macterm itself wrote.
        let declared = layout.declaredName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (declared?.isEmpty == false ? declared : nil)
            ?? layout.url.deletingPathExtension().lastPathComponent
        let project = projectStore.create(name: name, path: path)
        appState.selectProject(project)
    }

    private func confirmDeletion() {
        guard let target = layoutPendingDeletion else { return }
        layoutPendingDeletion = nil
        do {
            try appState.projectFiles.delete(at: target.url)
        } catch {
            deleteFailure = error.localizedDescription
        }
        reloadLayouts()
    }

    private func revealLayoutFolder() {
        let dir = ProjectFileStore.defaultDirectory()
        // The directory is created lazily on the first save, so a reveal before
        // then would silently do nothing.
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path(percentEncoded: false))
    }
}

// MARK: - Project row

/// One project: its name, path, load state, and its actions. Actions live in a
/// menu rather than a row of buttons — six projects × six buttons is a wall of
/// chrome, and the menu is what the sidebar's context menu already is.
private struct ProjectRow: View {
    let project: Project
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    /// Opens the zmx install sheet for a remote project (#699).
    let onInstallZmx: () -> Void

    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore

    var body: some View {
        HStack(spacing: 8) {
            // `AnyShapeStyle` because the two arms are different style types
            // (a concrete `Color` and the hierarchical `.secondary`), which a
            // `??` can't reconcile on its own.
            Image(systemName: project.isRemote ? "network" : "folder")
                .foregroundStyle(project.color.map { AnyShapeStyle(MactermTheme.color(for: $0)) } ?? AnyShapeStyle(.secondary))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                Text(project.path)
                    .settingsSecondaryText()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Menu {
                // Every mutation here stages its dialogs on this window
                // (`host: .settings`), so the main window's copies stay quiet —
                // see `AppState.DialogHost`.
                Button("Apply Layout") {
                    appState.applyLayoutPresentingError(project, host: .settings)
                }
                .disabled(!canApplyLayout)

                Button("Save Layout") {
                    appState.saveLayoutPresentingError(
                        project,
                        siblingProjects: projectStore.projects,
                        host: .settings
                    )
                    appState.noteLayoutFilesChanged()
                }
                .disabled(appState.workspaces[project.id] == nil)

                if project.isRemote {
                    Divider()

                    // Install or update: the sheet decides which after it
                    // asked the host.
                    Button("Install zmx on Host…") { onInstallZmx() }
                }

                Divider()

                ProjectColorMenu(selection: project.color) { color in
                    projectStore.setColor(id: project.id, to: color)
                }

                Divider()

                Button("Move Up") { onMoveUp() }
                    .disabled(!canMoveUp)

                Button("Move Down") { onMoveDown() }
                    .disabled(!canMoveDown)

                Divider()

                Button("Remove", role: .destructive) {
                    appState.requestRemoveProject(project.id, host: .settings) {
                        appState.removeProject(project.id)
                        projectStore.remove(id: project.id)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    /// Mirrors the palette's muted state: a file that declares no tabs has
    /// nothing to apply, while an unparseable one stays enabled so invoking it
    /// surfaces the parse error instead of silently doing nothing.
    private var canApplyLayout: Bool {
        switch appState.projectFiles.applyState(
            forProjectPath: project.path,
            preferredSlug: ProjectSlug.slug(from: project.name)
        ) {
        case .applicable,
             .invalid: true
        case .none,
             .emptyTabs: false
        }
    }
}

// MARK: - Layout row

private struct LayoutRow: View {
    let layout: ProjectFileStore.Listing
    let hasProject: Bool
    let onCreateProject: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: layout.isInvalid ? "exclamationmark.triangle" : "doc.text")
                .foregroundStyle(layout.isInvalid ? AnyShapeStyle(MactermTheme.warning) : AnyShapeStyle(.secondary))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(layout.filename)
                Text(subtitle)
                    .settingsSecondaryText()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Menu {
                Button(hasProject ? "Create Another Project" : "Create Project") { onCreateProject() }
                    .disabled(layout.declaredPath == nil)
                Divider()
                Button("Remove", role: .destructive) { onRemove() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if layout.isInvalid {
            return String(localized: "Invalid file. Fix it in an editor to use it.")
        }
        guard let path = layout.declaredPath else {
            return String(localized: "No path declared.")
        }
        return switch layout.tabCount {
        case 0: String(localized: "\(path) — no tabs", comment: "Settings → Layouts: a layout file's path and tab count")
        case 1: String(localized: "\(path) — 1 tab", comment: "Settings → Layouts: a layout file's path and tab count")
        default: String(localized: "\(path) — \(layout.tabCount) tabs", comment: "Settings → Layouts: a layout file's path and tab count")
        }
    }
}
