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
    @State private var deleteFailure: String?

    var body: some View {
        Form {
            Section {
                if projectStore.projects.isEmpty {
                    Text("No projects.")
                        .foregroundStyle(.secondary)
                } else {
                    // `.onMove` is safe here, unlike the sidebar's list — this
                    // one has no tab rows or keyboard routing to hijack.
                    // `.plain` + a clear row background keeps every row on the
                    // section's own material: the default styles paint their
                    // own (alternating, in the case of the inset list), which
                    // reads as a second surface floating inside the group.
                    List {
                        ForEach(projectStore.projects) { project in
                            ProjectRow(project: project)
                                .listRowBackground(Color.clear)
                        }
                        .onMove { source, destination in
                            projectStore.reorder(fromOffsets: source, toOffset: destination)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: 220)
                }
                Text("Drag to reorder.")
                    .settingsCaption()
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

            Section("Layouts") {
                if layouts.isEmpty {
                    Text("No layout files.")
                        .foregroundStyle(.secondary)
                } else {
                    List(layouts) { layout in
                        LayoutRow(
                            layout: layout,
                            hasProject: hasProject(for: layout),
                            onCreateProject: { createProject(from: layout) },
                            onRemove: { layoutPendingDeletion = layout }
                        )
                        .listRowBackground(Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120, maxHeight: 220)
                }
                LabeledContent("Folder") {
                    Button(ProjectFileStore.defaultDirectory().path(percentEncoded: false)) {
                        revealLayoutFolder()
                    }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                Text("Removing a layout deletes its file. The project is kept.")
                    .settingsCaption()
            }
        }
        .formStyle(.grouped)
        .onAppear { reloadLayouts() }
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
            Button("Remove", role: .destructive) { confirmDeletion() }
        } message: {
            Text("“\(layoutPendingDeletion?.filename ?? "")” will be deleted. Projects using it are kept, but lose their saved layout.")
        }
        .alert(
            "Couldn’t remove layout file",
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

    /// Add a project for this file's declaration and select it. Selecting is
    /// what makes the layout take effect: a project with no workspace yet
    /// auto-applies its matching file on first open.
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

/// One project: its name, path, load state, and the four actions. Actions live
/// in a menu rather than a row of buttons — six projects × four buttons is a
/// wall of chrome, and the menu is what the sidebar's context menu already is.
private struct ProjectRow: View {
    let project: Project

    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore

    private var isLoaded: Bool { appState.isProjectLoaded(project.id) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: project.isRemote ? "network" : "folder")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                Text(project.path)
                    .settingsCaption()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            // Only the exception is worth a badge — a loaded project is the
            // ordinary state, so labeling every row adds noise, not signal.
            if !isLoaded {
                UnloadedBadge()
            }

            Menu {
                Button("Apply Layout") {
                    appState.applyLayoutPresentingError(project)
                }
                .disabled(!canApplyLayout)

                Button("Save Layout") {
                    appState.saveLayoutPresentingError(project, siblingProjects: projectStore.projects)
                    appState.noteLayoutFilesChanged()
                }
                .disabled(appState.workspaces[project.id] == nil)

                Divider()

                Button("Unload") { appState.requestUnloadProject(project.id) }
                    .disabled(!isLoaded)

                Button("Remove", role: .destructive) {
                    appState.requestRemoveProject(project.id) {
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

/// Marks a project with no running terminals — the state it sits in before its
/// first open and after Unload, where the workspace layout exists but no shell
/// does. Loaded projects carry no badge.
private struct UnloadedBadge: View {
    var body: some View {
        Text("Unloaded")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.quaternary))
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
                    .settingsCaption()
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
            return "Invalid file — fix it in an editor to use it."
        }
        guard let path = layout.declaredPath else {
            return "No path declared."
        }
        let tabs = layout.tabCount == 1 ? "1 tab" : "\(layout.tabCount) tabs"
        return layout.tabCount == 0 ? "\(path) — no tabs" : "\(path) — \(tabs)"
    }
}
