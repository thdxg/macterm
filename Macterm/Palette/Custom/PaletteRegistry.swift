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
/// hour (`refreshInterval`), never in the background. Installing copies the
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
    }

    struct Entry: Identifiable, Equatable {
        /// The folder's name: the installed extension's id.
        let id: String
        let files: [File]
        /// Each text file's contents, by path — everything but images —
        /// read once, so what Install writes is exactly what was validated.
        let texts: [String: String]
        let manifest: Result<ExtensionManifest, CustomPaletteError>
        /// Each palette in `palettes/`, by path, as this build reads it or
        /// why it can't.
        let palettes: [(path: String, result: Result<CustomPalette, CustomPaletteError>)]

        init(id: String, files: [File], texts: [String: String]) {
            self.id = id
            self.files = files
            self.texts = texts
            if let manifestText = texts[MactermExtension.manifestName] {
                manifest = Self.read { try ExtensionManifest.parse(yaml: manifestText) }
            } else {
                manifest = .failure(.invalid("no \(MactermExtension.manifestName)"))
            }
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
            lhs.id == rhs.id && lhs.files == rhs.files && lhs.texts == rhs.texts
        }

        /// Why it can't be installed: its manifest or one of its palettes
        /// doesn't read in this build, or it has no palette at all.
        var failure: CustomPaletteError? {
            if case let .failure(error) = manifest { return error }
            for palette in palettes {
                if case let .failure(error) = palette.result {
                    return .invalid("\(palette.path): \(error.localizedDescription)")
                }
            }
            if palettes.isEmpty { return .invalid("no palettes in \(MactermExtension.palettesFolder)/") }
            return nil
        }

        var name: String { (try? manifest.get())?.name ?? id }
        var icon: String { (try? manifest.get())?.icon ?? MactermExtension.defaultIcon }
        var description: String? { try? manifest.get().description }
        var authors: [String] { (try? manifest.get())?.authors ?? [] }
        var readme: String? { texts[MactermExtension.readmeName] }
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

    init(
        ref: String = PaletteRegistry.defaultRef,
        fetch: @escaping Fetch = PaletteRegistry.fetchFromNetwork
    ) {
        self.ref = ref
        self.fetch = fetch
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
            }

            let tree: [Item]
        }
        var byID: [String: [File]] = [:]
        for item in try JSONDecoder().decode(Tree.self, from: data).tree where item.type == "blob" {
            let parts = item.path.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, !parts[1].split(separator: "/").contains("..") else { continue }
            byID[parts[0], default: []].append(File(path: parts[1], size: item.size ?? 0, executable: item.mode == "100755"))
        }
        return byID
            .filter { _, files in files.contains { $0.path == MactermExtension.manifestName } }
            .map { (id: $0.key, files: $0.value.sorted { $0.path < $1.path }) }
            .sorted { $0.id < $1.id }
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
                outcome = .success(extensions.map { Entry(id: $0.id, files: $0.files, texts: texts[$0.id] ?? [:]) })
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case let .success(entries):
                self.entries = entries
                state = .loaded(Date())
            case let .failure(error):
                logger.error("extension registry: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    struct RegistryError: LocalizedError {
        let status: Int
        let ref: String
        var errorDescription: String? {
            status == 404 ? "Macterm's repository has no extensions at \(ref)." : "GitHub answered \(status)."
        }
    }

    enum InstallError: LocalizedError, Equatable {
        case alreadyInstalled(String)
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case let .alreadyInstalled(id): "You already have a palette named \(id)."
            case let .unreadable(reason): "This version of Macterm can't read it: \(reason)"
            }
        }
    }

    /// Copies `entry`'s folder into `store`'s extensions folder as `<id>/`
    /// and reloads the store, so it is installed at once — the text already
    /// read, images fetched now, executables kept executable. Written beside
    /// the destination and moved into place, so a failed download leaves no
    /// half an extension. Never replaces a palette the user has: one of
    /// that id, a file or an installed extension, refuses.
    @discardableResult
    func install(_ entry: Entry, into store: CustomPaletteStore) async throws -> URL {
        if let failure = entry.failure { throw InstallError.unreadable(failure.localizedDescription) }
        let fm = FileManager.default
        let destination = store.extensionsURL.appendingPathComponent(entry.id, isDirectory: true)
        if store.installedExtension(id: entry.id) != nil || fm.fileExists(atPath: destination.path) {
            throw InstallError.alreadyInstalled(entry.id)
        }
        var contents: [String: Data] = entry.texts.mapValues { Data($0.utf8) }
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

/// One card in Settings → Extensions: an installed extension — a folder in
/// the extensions folder, or a palette file of the user's own — or one from
/// the repository not installed yet. The built-in screens aren't
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

    var title: String {
        switch self {
        case let .installed(installed, _): installed.name
        case let .available(entry): entry.name
        }
    }

    var summary: String {
        switch self {
        case let .installed(installed, _): installed.problem ?? installed.description ?? installed.id
        case let .available(entry): entry.failure.map { "Can't be read by this version: \($0.localizedDescription)" }
            ?? entry.description ?? entry.readme.flatMap(MactermExtension.summary(readme:)) ?? ""
        }
    }

    var icon: String {
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

    /// Which extensions the gallery shows: the segmented filter beside its
    /// search.
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case installed = "Installed"
        case notInstalled = "Not Installed"

        var id: String { rawValue }
    }

    /// The extensions `filter` admits, the installed ones once each and
    /// before the rest, each group by name — or ranked by `query` (the app's
    /// one search, as every Settings list) when there is one.
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
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.summary == rhs.summary
    }
}
