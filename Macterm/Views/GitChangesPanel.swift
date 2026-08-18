import SwiftUI

/// Read-only view of a project's uncommitted changes, docked beside the
/// terminal: one collapsible section per changed file, each holding that
/// file's unified diff. Nothing here writes to the repository — no staging, no
/// commit, no discard — so a mistake in the panel can cost at most a redraw.
///
/// A column in the detail area rather than a pane in the split tree:
/// `SplitNode` only knows `.pane(Pane)`, and a `Pane` owns a ghostty surface,
/// so the tree cannot hold a non-terminal view at all. Teaching it one is a
/// much larger change; docking beside the workspace answers the same question
/// without pretending the architecture already allows it.
struct GitChangesPanel: View {
    @Environment(AppState.self)
    private var appState
    @Environment(ProjectStore.self)
    private var projectStore

    @State
    private var model = GitChangesModel()

    private var project: Project? {
        projectStore.projects.first { $0.id == appState.activeProjectID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            summaryBar
            Divider()
            content
        }
        .background(MactermTheme.bg)
        .task(id: project?.id) {
            await model.load(project: project)
        }
        // The panel is a window fixture, not a modal: switching tabs is how a
        // user gets to the change they just made, so re-read on that edge
        // instead of making them reach for Refresh every time.
        .onChange(of: appState.workspaces[appState.activeProjectID ?? UUID()]?.activeTabID) {
            Task { await model.load(project: project) }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 6) {
            Text(model.title)
                .font(.system(size: 11))
                .foregroundStyle(MactermTheme.fgMuted)
                .lineLimit(1)
                .truncationMode(.head)
            if let branch = model.branchLabel {
                Text(branch)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(MactermTheme.fg)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
            Button {
                appState.isGitChangesPanelVisible = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(MactermTheme.fgMuted)
            .help("Close Repository Changes")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var summaryBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .foregroundStyle(MactermTheme.fgMuted)
            Text(model.summaryLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MactermTheme.fg)
            Spacer(minLength: 6)
            if !model.changes.isEmpty {
                DiffCountBadge(additions: model.totalAdditions, deletions: model.totalDeletions)
            }
            Button {
                Task { await model.load(project: project) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(MactermTheme.fgMuted)
            .disabled(model.isLoading)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(MactermTheme.surface)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            centered {
                ProgressView()
                    .controlSize(.small)
            }
        case .noProject:
            centered { message("No project selected") }
        case .remoteProject:
            centered { message("Remote projects aren't supported yet — git runs on this Mac, not on the host.") }
        case .notARepository:
            centered { message("This project isn't inside a git repository.") }
        case let .failed(reason):
            centered { message(reason) }
        case .loaded where model.changes.isEmpty:
            centered { message("No uncommitted changes") }
        case .loaded:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(model.changes) { change in
                        GitChangeSection(
                            change: change,
                            isExpanded: model.isExpanded(change.path),
                            lines: model.diffLines(for: change.path),
                            imagePreview: model.imagePreview(for: change.path),
                            isLoading: model.isFetching(change.path),
                            onToggle: {
                                Task { await model.toggle(change, project: project) }
                            },
                            onAppear: {
                                // Fires when the row is actually built, which
                                // in a LazyVStack means "scrolled into view" —
                                // that is the whole loading strategy: the top
                                // of the list costs one `git diff`, and the
                                // rest cost nothing until the user goes there.
                                Task { await model.ensureDiff(change, project: project) }
                            }
                        )
                    }
                }
                .padding(8)
            }
        }
    }

    private func centered(@ViewBuilder content: () -> some View) -> some View {
        VStack {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(MactermTheme.fgMuted)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)
    }
}

/// How many diff rows a section renders — and, therefore, how many lines the
/// parser bothers to tokenize. A single file's diff can be tens of thousands
/// of lines (a lockfile, a generated migration); past this the section says
/// how many it dropped rather than truncating silently. Shared so the render
/// bound and the tokenize bound can never disagree.
private let diffRenderedLineLimit = 2000

/// The two sides of a changed image. Bytes, not `NSImage`s: decoding happens
/// in the view, on the main actor, because `NSImage` is not `Sendable` and the
/// loading path crosses actors.
struct GitImagePreview {
    let before: Data?
    let after: Data?

    var isEmpty: Bool { before == nil && after == nil }
}

/// Before/after thumbnails for an image change. A deletion shows only the old
/// version, an addition only the new — which side is missing is itself the
/// information, so an absent image is labelled rather than left blank.
private struct GitImagePreviewView: View {
    let preview: GitImagePreview

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let before = preview.before {
                thumbnail(before, caption: "before")
            }
            if let after = preview.after {
                thumbnail(after, caption: "after")
            }
            if preview.isEmpty {
                Text("Preview unavailable — the file is too large or isn't a readable image.")
                    .font(.system(size: 10))
                    .foregroundStyle(MactermTheme.fgDim)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
    }

    private func thumbnail(_ data: Data, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 180, maxHeight: 140)
                    .background(MactermTheme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(MactermTheme.border, lineWidth: 1)
                    }
                Text("\(caption) · \(Int(image.size.width))×\(Int(image.size.height)) · \(byteLabel(data.count))")
                    .font(.system(size: 9))
                    .foregroundStyle(MactermTheme.fgDim)
            } else {
                Text("\(caption) · not decodable")
                    .font(.system(size: 9))
                    .foregroundStyle(MactermTheme.fgDim)
            }
        }
    }

    private func byteLabel(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

// MARK: - One file

/// A file's row plus, when open, its diff. Collapsed by default: a repository
/// mid-feature routinely has more changed lines than fit on screen, and a list
/// that opens everything buries the file names the panel exists to show.
private struct GitChangeSection: View {
    let change: GitFileChange
    let isExpanded: Bool
    let lines: [GitDiffLine]
    let imagePreview: GitImagePreview?
    let isLoading: Bool
    let onToggle: () -> Void
    let onAppear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(MactermTheme.fgDim)
                        .frame(width: 10)
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(change.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MactermTheme.fg)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 6)
                    if change.isStaged {
                        // The one piece of index state a row shows: a commit
                        // right now would capture this file, and nothing else
                        // in the panel would say so.
                        Text("staged")
                            .font(.system(size: 9))
                            .foregroundStyle(MactermTheme.fgDim)
                    }
                    if change.additions > 0 || change.deletions > 0 {
                        DiffCountBadge(additions: change.additions, deletions: change.deletions)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                } else if let imagePreview {
                    GitImagePreviewView(preview: imagePreview)
                } else if lines.isEmpty {
                    Text("No textual diff")
                        .font(.system(size: 10))
                        .foregroundStyle(MactermTheme.fgDim)
                        .padding(8)
                } else {
                    // NO horizontal ScrollView around this stack: it sizes
                    // itself by measuring every row, which defeats the
                    // LazyVStack and lays out every line of every open file
                    // at once. Long lines truncate instead; the terminal is
                    // right there for reading a whole one.
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(lines.prefix(diffRenderedLineLimit)) { line in
                            DiffLineView(line: line)
                        }
                        if lines.count > diffRenderedLineLimit {
                            Text("… \(lines.count - diffRenderedLineLimit) more lines")
                                .font(.system(size: 10))
                                .foregroundStyle(MactermTheme.fgDim)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(MactermTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(MactermTheme.border, lineWidth: 1)
        }
        .onAppear(perform: onAppear)
    }

    private var symbol: String {
        switch change.displayState {
        case .added,
             .untracked: "plus.circle"
        case .deleted: "minus.circle"
        case .renamed,
             .copied: "arrow.right.circle"
        case .conflicted: "exclamationmark.triangle"
        case .typeChanged,
             .modified,
             .ignored: "circle.fill"
        }
    }

    private var tint: Color {
        switch change.displayState {
        case .added,
             .untracked: MactermTheme.success
        case .deleted,
             .conflicted: MactermTheme.danger
        default: MactermTheme.warning
        }
    }
}

private struct DiffCountBadge: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)")
                .foregroundStyle(MactermTheme.success)
            Text("−\(deletions)")
                .foregroundStyle(MactermTheme.danger)
        }
        .font(.system(size: 10, design: .monospaced))
    }
}

private struct DiffLineView: View {
    let line: GitDiffLine

    var body: some View {
        HStack(spacing: 0) {
            Text(line.displayNumber.map(String.init) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(MactermTheme.fgDim)
                .frame(width: 38, alignment: .trailing)
                .padding(.trailing, 8)
            code
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
        }
        .padding(.vertical, 0.5)
        .background(background)
    }

    /// A hunk header is git's own text, not the file's, so it stays whole and
    /// unhighlighted. Everything else drops its leading marker column (`+`,
    /// `-`, or the context space): the row's tint already says which it is,
    /// and keeping the marker shifts every line one column off the gutter.
    @ViewBuilder
    private var code: some View {
        if line.kind == .hunk {
            Text(line.text)
                .foregroundStyle(MactermTheme.accent)
        } else if line.tokens.isEmpty {
            Text(" ")
        } else {
            highlighted(line.tokens)
        }
    }

    /// Concatenating `Text` keeps the whole line ONE view: a per-token HStack
    /// would break selection into fragments and lose the exact monospaced
    /// advance between runs. The tokens themselves come precomputed from the
    /// parser — building them here would run on every layout pass.
    private func highlighted(_ tokens: [SyntaxToken]) -> Text {
        tokens.reduce(Text("")) { partial, token in
            partial + Text(token.text).foregroundColor(color(for: token.kind))
        }
    }

    private func color(for kind: SyntaxToken.Kind) -> Color {
        switch kind {
        case .keyword: MactermTheme.syntaxKeyword
        case .string: MactermTheme.syntaxString
        case .number: MactermTheme.syntaxNumber
        case .comment: MactermTheme.syntaxComment
        case .plain: MactermTheme.fg
        }
    }

    private var background: Color {
        switch line.kind {
        case .addition: MactermTheme.success.opacity(0.12)
        case .deletion: MactermTheme.danger.opacity(0.12)
        default: .clear
        }
    }
}

// MARK: - Model

/// Panel-local state. Deliberately NOT part of `AppState`: nothing here is
/// persisted and no other view reads it — the rule that workspace/tab/pane
/// mutations go through `AppState` is about state the app owns, not a
/// read-only view's cache. (The panel's VISIBILITY does live in `AppState`,
/// because the toolbar button and the palette command both drive it.)
@MainActor
@Observable
final class GitChangesModel {
    enum State: Equatable {
        case loading
        case noProject
        case remoteProject
        case notARepository
        case failed(String)
        case loaded
    }

    private(set) var state: State = .loading
    private(set) var changes: [GitFileChange] = []
    private(set) var repository: GitClient.Repository?
    private(set) var isLoading = false

    /// Diffs are kept once fetched, so collapsing and re-opening a section
    /// costs nothing. A reload drops the cache — the point of reloading is
    /// that the contents may have changed.
    private var diffs: [String: [GitDiffLine]] = [:]
    /// Sections the user has explicitly COLLAPSED. Tracking the negative is
    /// what makes "open by default" survive a reload: a set of expanded paths
    /// would have to be re-seeded on every load, which would also re-open
    /// everything the user just closed.
    private var collapsed: Set<String> = []

    /// Paths whose `git diff` is running right now, so a section that
    /// re-appears mid-scroll doesn't start a second one.
    private var fetching: Set<String> = []

    /// Decoded image previews, keyed like `diffs`. An image change has no
    /// textual diff to show — git only says "Binary files differ" — so the
    /// section shows the two versions instead.
    private var images: [String: GitImagePreview] = [:]

    /// Refuse to load an image bigger than this into memory for a thumbnail.
    /// A repository can legitimately hold a 200 MB PSD, and the panel is not
    /// worth an out-of-memory kill.
    private static let maxPreviewBytes = 24 * 1024 * 1024

    var totalAdditions: Int { changes.reduce(0) { $0 + $1.additions } }
    var totalDeletions: Int { changes.reduce(0) { $0 + $1.deletions } }

    var title: String {
        guard let repository else { return "Repository Changes" }
        return ProjectPath.homeContracted(repository.root)
    }

    var branchLabel: String? {
        guard let repository else { return nil }
        return repository.branch ?? "detached HEAD"
    }

    var summaryLabel: String {
        switch changes.count {
        case 0: "Uncommitted changes"
        case 1: "Uncommitted changes · 1 file"
        default: "Uncommitted changes · \(changes.count) files"
        }
    }

    /// Open unless the user closed it. There is no cap on how many sections
    /// open: a section costs nothing until it scrolls into view, which is what
    /// makes "everything expanded" affordable on a repository with hundreds of
    /// changed files.
    func isExpanded(_ path: String) -> Bool {
        !collapsed.contains(path)
    }

    func isFetching(_ path: String) -> Bool {
        fetching.contains(path)
    }

    func imagePreview(for path: String) -> GitImagePreview? {
        images[path]
    }

    func diffLines(for path: String) -> [GitDiffLine] {
        diffs[path] ?? []
    }

    func load(project: Project?) async {
        guard let project else {
            state = .noProject
            return
        }
        guard !project.isRemote else {
            state = .remoteProject
            return
        }
        isLoading = true
        defer { isLoading = false }
        let directory = ProjectPath.canonicalLocal(project.path)
        switch await GitClient.repository(at: directory) {
        case let .success(repository):
            self.repository = repository
            changes = await GitClient.changes(at: directory)
            diffs = [:]
            // Drop collapse marks for files that are no longer changed; a
            // stale key would keep a later, unrelated change closed.
            collapsed = collapsed.intersection(Set(changes.map(\.path)))
            images = [:]
            state = .loaded
        case let .failure(failure):
            repository = nil
            changes = []
            diffs = [:]
            state = failure == .notARepository ? .notARepository : .failed("git couldn't read this directory.")
        }
    }

    func toggle(_ change: GitFileChange, project: Project?) async {
        if isExpanded(change.path) {
            collapsed.insert(change.path)
            return
        }
        collapsed.remove(change.path)
        await ensureDiff(change, project: project)
    }

    /// Fetch a file's diff unless it is cached or already in flight. Every
    /// path into a diff goes through here — the section appearing, a manual
    /// expand — so a file is never fetched twice.
    func ensureDiff(_ change: GitFileChange, project: Project?) async {
        guard isExpanded(change.path), !fetching.contains(change.path) else { return }
        if change.isImage {
            guard images[change.path] == nil else { return }
            fetching.insert(change.path)
            defer { fetching.remove(change.path) }
            await fetchImage(change)
            return
        }
        guard diffs[change.path] == nil else { return }
        fetching.insert(change.path)
        defer { fetching.remove(change.path) }
        await fetchDiff(change, project: project)
    }

    /// Load both sides of an image change. Which sides EXIST is what the
    /// status already told us: an untracked or added file has no HEAD version,
    /// a deleted one has no file on disk, and asking for the missing side
    /// would spend a subprocess to be told so.
    private func fetchImage(_ change: GitFileChange) async {
        guard let root = repository?.root else { return }
        let wantsBefore = change.displayState != .untracked && change.displayState != .added
        let wantsAfter = change.displayState != .deleted
        async let before = wantsBefore ? GitClient.fileData(for: change.path, revision: "HEAD", in: root) : nil
        async let after = wantsAfter ? GitClient.fileData(for: change.path, revision: nil, in: root) : nil
        let preview = await GitImagePreview(
            before: bounded(before),
            after: bounded(after)
        )
        guard changes.contains(where: { $0.path == change.path }) else { return }
        images[change.path] = preview
    }

    private func bounded(_ data: Data?) -> Data? {
        guard let data, data.count <= Self.maxPreviewBytes else { return nil }
        return data
    }

    private func fetchDiff(_ change: GitFileChange, project: Project?) async {
        guard let project, !project.isRemote else { return }
        let raw = await GitClient.diff(for: change, at: ProjectPath.canonicalLocal(project.path))
        await store(raw, for: change.path)
    }

    /// Parse OFF the main actor. Classifying, numbering and tokenizing a big
    /// diff is tens of milliseconds of pure CPU per file, and doing it inline
    /// here — the model is `@MainActor` — froze the panel on "loading" for as
    /// long as it took.
    private static func parse(_ raw: String, path: String) async -> [GitDiffLine] {
        let language = SyntaxLanguage.forPath(path)
        let limit = diffRenderedLineLimit
        return await Task.detached(priority: .userInitiated) {
            GitDiffParser.lines(raw, language: language, tokenLimit: limit)
                .filter { $0.kind != .meta }
        }.value
    }

    private func store(_ raw: String, for path: String) async {
        // A reload may have landed while the subprocess ran; dropping the
        // answer for a file that is no longer listed keeps the cache honest.
        guard changes.contains(where: { $0.path == path }) else { return }
        // `diff --git …`, `index abc..def`, `--- a/x`, `+++ b/x`: git's
        // framing, not the file's content. The panel already names the file in
        // its section header, so showing them again pushes the first real line
        // four rows down in every section.
        diffs[path] = await Self.parse(raw, path: path)
    }
}
