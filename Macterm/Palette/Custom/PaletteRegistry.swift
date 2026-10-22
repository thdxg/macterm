import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "PaletteRegistry")

/// The extensions anyone can install (`extensions/` in Macterm's repository,
/// one folder each — `MactermExtension`), read from GitHub for Settings →
/// Extensions. Every build reads `main`: extensions aren't tied to a
/// version, because the format only ever grows — an extension that works
/// keeps working in every later Macterm. Each is still run through this
/// build's validator, so one using something newer than this build is shown
/// with why, and can't be installed until Macterm is updated.
///
/// One request lists every extension's files (GitHub's Git Trees API, at
/// `<ref>:extensions`); their text — manifest, palettes, README, any script —
/// comes from `raw.githubusercontent.com`, which the API's hourly limit
/// doesn't count. Read each time Settings → Extensions opens, at most once an
/// hour (`refreshInterval`), never in the background. Screenshots are read
/// only when a card shows them (`ExtensionScreenshotLoader`). Installing copies the
/// folder into `~/.config/macterm/extensions/<id>/`; nothing here runs its
/// commands.
@MainActor @Observable
final class PaletteRegistry {
    /// A file in an extension's folder.
    struct File: Equatable {
        /// Relative to the folder.
        let path: String
        let size: Int
        let executable: Bool
        /// Its Git blob SHA at the ref (`ExtensionSource.blobSHA`).
        let sha: String

        init(path: String, size: Int, executable: Bool, sha: String = "") {
            self.path = path
            self.size = size
            self.executable = executable
            self.sha = sha
        }
    }

    struct Entry: Identifiable, Equatable {
        /// The folder's name: the installed extension's id.
        let id: String
        let files: [File]
        /// Each text file's contents, by path — everything but images —
        /// read once, so what Install writes is exactly what was validated.
        let texts: [String: String]
        /// The icon file that the manifest names, by path, when there is one
        /// — the one image read before Install, so that the card shows it.
        let images: [String: Data]
        let manifest: Result<ExtensionManifest, CustomPaletteError>
        /// What its card shows (`MactermExtension.icon(of:file:)`), and why
        /// its icon file can't be used, if it can't.
        let icon: PaletteIcon
        let iconProblem: String?
        /// Each palette in `palettes/`, by path, as this build reads it or
        /// why it can't.
        let palettes: [(path: String, result: Result<CustomPalette, CustomPaletteError>)]

        init(id: String, files: [File], texts: [String: String], images: [String: Data] = [:]) {
            self.id = id
            self.files = files
            self.texts = texts
            self.images = images
            if let manifestText = texts[MactermExtension.manifestName] {
                manifest = Self.read { try ExtensionManifest.parse(yaml: manifestText) }
            } else {
                manifest = .failure(.invalid("no \(MactermExtension.manifestName)"))
            }
            (icon, iconProblem) = MactermExtension.icon(of: try? manifest.get()) { images[$0] }
            palettes = files.map(\.path).filter(MactermExtension.isPalette).map { path in
                let paletteID = MactermExtension.paletteID(extensionID: id, path: path)
                return (path, Self.read { try CustomPalette(file: CustomPaletteFile.parse(yaml: texts[path] ?? ""), id: paletteID) })
            }
        }

        private static func read<T>(_ body: () throws -> T) -> Result<T, CustomPaletteError> {
            do {
                return try .success(body())
            } catch let error as CustomPaletteError {
                return .failure(error)
            } catch {
                return .failure(.parse(underlying: error))
            }
        }

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.id == rhs.id && lhs.files == rhs.files && lhs.texts == rhs.texts && lhs.images == rhs.images
        }

        /// Why it can't be installed: its manifest or one of its palettes
        /// doesn't read in this build, it has no palette at all, or its icon
        /// file is missing or the wrong size.
        var failure: CustomPaletteError? {
            if case let .failure(error) = manifest { return error }
            if let iconProblem { return .invalid("\(MactermExtension.manifestName): \(iconProblem)") }
            for palette in palettes {
                if case let .failure(error) = palette.result {
                    return .invalid("\(palette.path): \(error.localizedDescription)")
                }
            }
            if palettes.isEmpty { return .invalid("no palettes in \(MactermExtension.palettesFolder)/") }
            return nil
        }

        var name: String { (try? manifest.get())?.name ?? id }
        var description: String? { try? manifest.get().description }
        var authors: [String] { (try? manifest.get())?.authors ?? [] }
        var readme: String? { texts[MactermExtension.readmeName] }
        /// Its files at the ref, by path, as Git blob SHAs: what an
        /// `ExtensionSource` records at install.
        /// Hidden files are left out, as `ExtensionSource.files(in:)` leaves
        /// them out on disk.
        var shas: [String: String] {
            Dictionary(
                files.filter { !$0.path.split(separator: "/").contains { $0.hasPrefix(".") } }.map { ($0.path, $0.sha) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    enum State: Equatable {
        case idle
        case loading
        case loaded(Date)
        case failed(String)
    }

    /// Fetches a URL: its body and HTTP status. Injected so tests serve the
    /// tree and files from memory.
    typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    nonisolated static let refreshInterval: TimeInterval = 3600
    nonisolated static let repository = "thdxg/macterm"
    nonisolated static let folder = "extensions"

    /// The repository's ref the extensions are read at: `main`.
    let ref: String
    private(set) var entries: [Entry] = []
    private(set) var state: State = .idle
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The extensions that an install or an update writes now. A click on
    /// Update and an automatic update must never write one folder at the
    /// same time.
    private(set) var writingIDs: Set<String> = []
    /// The screenshots of the cards, read when a card shows them, through
    /// the same `fetch`.
    @ObservationIgnored let screenshots: ExtensionScreenshotLoader

    init(
        ref: String = PaletteRegistry.defaultRef,
        fetch: @escaping Fetch = PaletteRegistry.fetchFromNetwork
    ) {
        self.ref = ref
        self.fetch = fetch
        screenshots = ExtensionScreenshotLoader(ref: ref, fetch: fetch)
    }

    /// `main`. A debug build can read another branch with
    /// `MACTERM_PALETTE_REF` — one whose extensions aren't merged yet.
    nonisolated static var defaultRef: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["MACTERM_PALETTE_REF"], !override.isEmpty { return override }
        #endif
        return "main"
    }

    /// Every file under `extensions/` at `ref`, in one request.
    nonisolated static func treeURL(ref: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(repository)/git/trees/\(ref):\(folder)"
        components.queryItems = [URLQueryItem(name: "recursive", value: "1")]
        // Every part is fixed but the ref, which `URLComponents` escapes.
        return components.url ?? URL(fileURLWithPath: "/")
    }

    /// An extension's folder on GitHub, at `ref` — what a card's link opens:
    /// every file it would install, with its README rendered below them, so
    /// it can be read before installing.
    nonisolated static func folderURL(ref: String, id: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(repository)/tree/\(ref)/\(folder)/\(id)"
        return components.url ?? URL(fileURLWithPath: "/")
    }

    /// A file of an extension, at `ref`, from GitHub's raw host.
    nonisolated static func fileURL(ref: String, id: String, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "raw.githubusercontent.com"
        components.path = "/\(repository)/\(ref)/\(folder)/\(id)/\(path)"
        return components.url ?? URL(fileURLWithPath: "/")
    }

    /// A Git tree of `extensions/`, as the extensions it holds: each folder
    /// with an `extension.yaml`, by id, with its files. Files at the top
    /// (the folder's README) belong to no extension.
    nonisolated static func parseTree(_ data: Data) throws -> [(id: String, files: [File])] {
        struct Tree: Decodable {
            struct Item: Decodable {
                let path: String
                let type: String
                let mode: String
                let size: Int?
                let sha: String?
            }

            let tree: [Item]
        }
        var byID: [String: [File]] = [:]
        for item in try JSONDecoder().decode(Tree.self, from: data).tree where item.type == "blob" {
            let parts = item.path.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].split(separator: "/").contains("..") else { continue }
            byID[parts[0], default: []].append(File(
                path: parts[1], size: item.size ?? 0, executable: item.mode == "100755", sha: item.sha ?? ""
            ))
        }
        return byID
            .filter { _, files in files.contains { $0.path == MactermExtension.manifestName } }
            .map { (id: $0.key, files: $0.value.sorted { $0.path < $1.path }) }
            .sorted { $0.id < $1.id }
    }

    /// `refresh`, and returns when the read is over: at once when the
    /// extensions were read in the last hour.
    func refreshAndWait() async {
        refresh()
        await task?.value
    }

    /// Reads the repository's extensions, unless they were read in the last
    /// hour; a read that failed is tried again.
    func refresh() {
        if state == .loading { return }
        if case let .loaded(date) = state, Date().timeIntervalSince(date) < Self.refreshInterval { return }
        state = .loading
        let fetch = fetch
        let ref = ref
        task = Task { @MainActor [weak self] in
            let outcome: Result<[Entry], Error>
            do {
                let (tree, status) = try await fetch(Self.treeURL(ref: ref))
                guard status == 200 else { throw RegistryError(status: status, ref: ref) }
                let extensions = try Self.parseTree(tree)
                let texts = try await withThrowingTaskGroup(of: (String, String, String).self) { group in
                    for (id, files) in extensions {
                        for file in files where !MactermExtension.isImage(file.path) {
                            group.addTask {
                                let (data, status) = try await fetch(Self.fileURL(ref: ref, id: id, path: file.path))
                                guard status == 200 else { throw RegistryError(status: status, ref: ref) }
                                return (id, file.path, String(decoding: data, as: UTF8.self))
                            }
                        }
                    }
                    var texts: [String: [String: String]] = [:]
                    for try await (id, path, text) in group {
                        texts[id, default: [:]][path] = text
                    }
                    return texts
                }
                // The icon file that each manifest names, when the folder has
                // it. A path that is not in the folder stays unread, and the
                // entry says so.
                let iconFiles: [(id: String, path: String)] = extensions.compactMap { id, files in
                    guard let text = texts[id]?[MactermExtension.manifestName],
                          let icon = (try? ExtensionManifest.parse(yaml: text))?.icon,
                          MactermExtension.isIconFile(icon), files.contains(where: { $0.path == icon })
                    else { return nil }
                    return (id, icon)
                }
                let images = try await withThrowingTaskGroup(of: (String, String, Data).self) { group in
                    for (id, path) in iconFiles {
                        group.addTask {
                            let (data, status) = try await fetch(Self.fileURL(ref: ref, id: id, path: path))
                            guard status == 200 else { throw RegistryError(status: status, ref: ref) }
                            return (id, path, data)
                        }
                    }
                    var images: [String: [String: Data]] = [:]
                    for try await (id, path, data) in group {
                        images[id, default: [:]][path] = data
                    }
                    return images
                }
                outcome = .success(extensions.map {
                    Entry(id: $0.id, files: $0.files, texts: texts[$0.id] ?? [:], images: images[$0.id] ?? [:])
                })
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case let .success(entries):
                self.entries = entries
                state = .loaded(Date())
            case let .failure(error):
                logger.error("extension registry: \(EnglishErrorText.describe(error), privacy: .public)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    struct RegistryError: LocalizedError {
        let status: Int
        let ref: String
        var errorDescription: String? {
            status == 404
                ? String(localized: "Macterm's repository has no extensions at \(ref).")
                : String(localized: "GitHub answered \(status).", comment: "The value is the HTTP status code of the answer from GitHub")
        }
    }

    enum InstallError: LocalizedError, Equatable {
        case alreadyInstalled(String)
        case notInstalled(String)
        case inProgress(String)
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case let .alreadyInstalled(id): String(localized: "You already have a palette named \(id).")
            case let .notInstalled(id): String(localized: "\(id) is not installed.")
            case let .inProgress(id): String(localized: "Macterm is already writing \(id).")
            case let .unreadable(reason): String(localized: "This version of Macterm cannot read it: \(reason)")
            }
        }
    }

    /// Copies `entry`'s folder into `store`'s extensions folder as `<id>/`
    /// (`write`) and reloads the store, so it is installed at once. Never
    /// replaces a palette the user has: one of that id, a file or an
    /// installed extension, refuses. `update` replaces one.
    @discardableResult
    func install(_ entry: Entry, into store: CustomPaletteStore) async throws -> URL {
        let destination = store.extensionsURL.appendingPathComponent(entry.id, isDirectory: true)
        if store.installedExtension(id: entry.id) != nil || FileManager.default.fileExists(atPath: destination.path) {
            throw InstallError.alreadyInstalled(entry.id)
        }
        return try await write(entry, into: store, replacing: nil)
    }

    /// Puts `entry` in place of the installed extension of its id, as Install
    /// writes it, and moves the old folder to the Trash — the undo, edits
    /// and all. Settings asks first when the old copy has changes of the
    /// user's own, or no source record (`ExtensionGalleryItem.update`).
    @discardableResult
    func update(_ entry: Entry, into store: CustomPaletteStore) async throws -> URL {
        guard let installed = store.installedExtension(id: entry.id) else { throw InstallError.notInstalled(entry.id) }
        return try await write(entry, into: store, replacing: installed.folder)
    }

    /// Writes a source record into each installed extension that has none
    /// and whose files are exactly those of the repository's extension of its
    /// id. That copy came from the repository, by an install from before the
    /// records, or by hand. With the record, a later change in the
    /// repository shows as an update and needs no confirmation. Settings
    /// calls it each time that the extensions are read.
    func adoptUnrecordedInstalls(in store: CustomPaletteStore) {
        var adopted = false
        for installed in store.extensions where installed.source == nil {
            guard let entry = entries.first(where: { $0.id == installed.id }), entry.shas == installed.files else { continue }
            do {
                try ExtensionSource(repository: Self.repository, ref: ref, files: entry.shas).write(in: installed.folder)
                adopted = true
            } catch {
                logger.error("source record for \(installed.id, privacy: .public): \(EnglishErrorText.describe(error), privacy: .public)")
            }
        }
        if adopted { store.reload() }
    }

    /// Install and Update: the text already read and the icon file read,
    /// other images fetched now, executables kept executable, and the source
    /// record. Written beside the destination and moved into place, so a
    /// failed download leaves no half an extension. `replacing` goes to the
    /// Trash just before the move.
    private func write(_ entry: Entry, into store: CustomPaletteStore, replacing old: URL?) async throws -> URL {
        if let failure = entry.failure { throw InstallError.unreadable(failure.localizedDescription) }
        guard writingIDs.insert(entry.id).inserted else { throw InstallError.inProgress(entry.id) }
        defer { writingIDs.remove(entry.id) }
        let fm = FileManager.default
        let destination = store.extensionsURL.appendingPathComponent(entry.id, isDirectory: true)
        var contents: [String: Data] = entry.texts.mapValues { Data($0.utf8) }.merging(entry.images) { text, _ in text }
        for file in entry.files where contents[file.path] == nil {
            let (data, status) = try await fetch(Self.fileURL(ref: ref, id: entry.id, path: file.path))
            guard status == 200 else { throw RegistryError(status: status, ref: ref) }
            contents[file.path] = data
        }
        try fm.createDirectory(at: store.extensionsURL, withIntermediateDirectories: true)
        let staging = store.extensionsURL.appendingPathComponent(".\(entry.id).installing-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        for file in entry.files {
            let url = staging.appendingPathComponent(file.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (contents[file.path] ?? Data()).write(to: url)
            if file.executable { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        }
        try ExtensionSource(repository: Self.repository, ref: ref, files: entry.shas).write(in: staging)
        if let old { try fm.trashItem(at: old, resultingItemURL: nil) }
        try fm.moveItem(at: staging, to: destination)
        store.reload()
        return destination
    }

    nonisolated static let fetchFromNetwork: Fetch = { url in
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Macterm", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// One card in Settings → Extensions: an installed extension (a folder in
/// the extensions folder), or one from the repository that is not installed. The built-in screens aren't
/// extensions and have no card.
enum ExtensionGalleryItem: Identifiable, Equatable {
    /// `registry` is the repository's entry of the same id, when there is one.
    case installed(CustomPaletteStore.InstalledExtension, registry: PaletteRegistry.Entry?)
    case available(PaletteRegistry.Entry)

    var id: String {
        switch self {
        case let .installed(installed, _): "installed:\(installed.id)"
        case let .available(entry): "available:\(entry.id)"
        }
    }

    /// The extension's id, installed or not.
    var extensionID: String {
        switch self {
        case let .installed(installed, _): installed.id
        case let .available(entry): entry.id
        }
    }

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    /// What Update offers on the card of an installed extension: the
    /// repository's version, when its files differ from the copy on disk.
    enum Update: Equatable {
        /// The copy is as Install wrote it. Update replaces it at once.
        case available(PaletteRegistry.Entry)
        /// The copy has changes of the user's own, or no record of where it
        /// came from. Update asks first, because the copy goes to the Trash.
        case replacesChanges(PaletteRegistry.Entry)

        var entry: PaletteRegistry.Entry {
            switch self {
            case let .available(entry),
                 let .replacesChanges(entry): entry
            }
        }
    }

    /// nil when there is nothing to update: the extension is not installed,
    /// the repository has no extension of its id, the copy is the same as
    /// the repository's, or the user changed a copy that the repository did
    /// not change since the install. That copy is the user's now, and nothing
    /// asks to replace it.
    var update: Update? {
        guard case let .installed(installed, entry?) = self, entry.shas != installed.files else { return nil }
        guard let source = installed.source else { return .replacesChanges(entry) }
        if source.files == entry.shas { return nil }
        return installed.isModified ? .replacesChanges(entry) : .available(entry)
    }

    var title: String {
        switch self {
        case let .installed(installed, _): installed.name
        case let .available(entry): entry.name
        }
    }

    var summary: String {
        switch self {
        case let .installed(installed, _): installed.problem ?? installed.description ?? installed.id
        case let .available(entry): entry.failure.map { String(localized: "Cannot be read by this version: \($0.localizedDescription)") }
            ?? entry.description ?? entry.readme.flatMap(MactermExtension.summary(readme:)) ?? ""
        }
    }

    var icon: PaletteIcon {
        switch self {
        case let .installed(installed, _): installed.icon
        case let .available(entry): entry.icon
        }
    }

    var authors: [String] {
        switch self {
        case let .installed(installed, _): installed.authors
        case let .available(entry): entry.authors
        }
    }

    /// The extensions that the gallery shows. The menu next to the search
    /// field sets this value.
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case installed = "Installed"
        case notInstalled = "Not Installed"

        var id: String { rawValue }
    }

    /// The extensions that `filter` lets through. Each installed extension
    /// is in the list one time, before the other extensions. Each group is
    /// in order of name. If there is a `query`, each group is in order of
    /// search rank instead (the search of the app, as in all Settings lists).
    static func items(
        installed: [CustomPaletteStore.InstalledExtension],
        registry: [PaletteRegistry.Entry],
        query: String,
        filter: Filter = .all
    ) -> [ExtensionGalleryItem] {
        let installedIDs = Set(installed.map(\.id))
        let byID = Dictionary(registry.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mine: [ExtensionGalleryItem] = filter == .notInstalled ? [] : installed.map { .installed($0, registry: byID[$0.id]) }
        let others: [ExtensionGalleryItem] = filter == .installed ? [] : registry.filter { !installedIDs.contains($0.id) }
            .map { .available($0) }
        let ordered = { (items: [ExtensionGalleryItem]) in
            Search.rank(items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }, by: query) {
                [$0.title, $0.summary]
            }
        }
        return ordered(mine) + ordered(others)
    }

    static func == (lhs: ExtensionGalleryItem, rhs: ExtensionGalleryItem) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.summary == rhs.summary && lhs.update == rhs.update
    }
}
