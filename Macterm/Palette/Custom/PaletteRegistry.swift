import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "PaletteRegistry")

/// The extensions anyone can install (`extensions/` in Macterm's repository,
/// one folder each — `MactermExtension`), read from GitHub for Settings →
/// Palettes. Read at the version this build came from (`ref(bundleID:version:)`),
/// so the gallery offers only extensions written for it, and each is run
/// through this build's validator: one it can't read is shown with why, and
/// can't be installed.
///
/// One request lists every extension's files (GitHub's Git Trees API, at
/// `<ref>:extensions`); their text — manifest, palette, README, any script —
/// comes from `raw.githubusercontent.com`, which the API's hourly limit
/// doesn't count, so it can be shown in full before installing. Fetched when
/// Settings → Palettes opens, at most once an hour (`refreshInterval`), or on
/// Refresh — never in the background. Installing copies the folder into
/// `~/.config/macterm/extensions/<id>/`; nothing here runs its commands.
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
        /// The folder's name: the installed palette's id.
        let id: String
        let files: [File]
        /// Each text file's contents, by path — everything but images, so
        /// what would run can be read before installing.
        let texts: [String: String]
        let manifest: Result<ExtensionManifest, CustomPaletteError>
        /// The palette as this build reads it, or why it can't.
        let result: Result<CustomPalette, CustomPaletteError>
        let header: CustomPaletteHeader?

        init(id: String, files: [File], texts: [String: String]) {
            self.id = id
            self.files = files
            self.texts = texts
            let paletteText = texts[MactermExtension.paletteName] ?? ""
            header = CustomPaletteFile.parseHeader(yaml: paletteText)
            if let manifestText = texts[MactermExtension.manifestName] {
                do {
                    manifest = try .success(ExtensionManifest.parse(yaml: manifestText))
                } catch let error as CustomPaletteError {
                    manifest = .failure(error)
                } catch {
                    manifest = .failure(.parse(underlying: error))
                }
            } else {
                manifest = .failure(.invalid("no \(MactermExtension.manifestName)"))
            }
            do {
                result = try .success(CustomPalette(file: CustomPaletteFile.parse(yaml: paletteText), id: id))
            } catch let error as CustomPaletteError {
                result = .failure(error)
            } catch {
                result = .failure(.parse(underlying: error))
            }
        }

        var palette: CustomPalette? { try? result.get() }
        /// Why it can't be installed: its manifest or its palette doesn't
        /// read in this build.
        var failure: CustomPaletteError? {
            if case let .failure(error) = manifest { return error }
            if case let .failure(error) = result { return error }
            return nil
        }

        var name: String { palette?.name ?? header?.name ?? id }
        var icon: String { palette?.icon ?? header?.icon ?? CustomPalette.defaultIcon }
        var description: String? { palette?.description ?? header?.description }
        var authors: [String] { (try? manifest.get())?.authors ?? [] }
        var readme: String? { texts[MactermExtension.readmeName] }
        /// Its screenshots' paths, in name order.
        var screenshots: [String] { files.map(\.path).filter(MactermExtension.isScreenshot) }
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

    /// The repository's ref this build reads: a debug build `main`, a tip
    /// build the rolling `tip` tag, a release or beta its own `v<version>`.
    let ref: String
    private(set) var entries: [Entry] = []
    private(set) var state: State = .idle
    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Screenshots fetched for the Install sheet, by URL, for the run.
    @ObservationIgnored private var images: [URL: Data] = [:]

    init(
        ref: String = PaletteRegistry.defaultRef,
        fetch: @escaping Fetch = PaletteRegistry.fetchFromNetwork
    ) {
        self.ref = ref
        self.fetch = fetch
    }

    /// This build's ref. A debug build can read another with
    /// `MACTERM_PALETTE_REF` — a branch whose extensions aren't on `main` yet.
    nonisolated static var defaultRef: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["MACTERM_PALETTE_REF"], !override.isEmpty { return override }
        #endif
        return ref(bundleID: appBundleID, version: appVersion)
    }

    nonisolated static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    nonisolated static func ref(bundleID: String, version: String) -> String {
        if bundleID.hasSuffix(".debug") { return "main" }
        if version.contains("-tip") { return "tip" }
        return "v\(version)"
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

    /// An extension's README on GitHub, at `ref`, rendered — what a card's
    /// link opens so it can be read before installing.
    nonisolated static func readmeURL(ref: String, id: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(repository)/blob/\(ref)/\(folder)/\(id)/\(MactermExtension.readmeName)"
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
    /// with a `palette.yaml`, by id, with its files. Files at the top
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
            .filter { _, files in files.contains { $0.path == MactermExtension.paletteName } }
            .map { (id: $0.key, files: $0.value.sorted { $0.path < $1.path }) }
            .sorted { $0.id < $1.id }
    }

    /// Reads the repository's extensions unless they were read within the
    /// hour; `force` reads them regardless (Refresh).
    func refresh(force: Bool = false) {
        if state == .loading { return }
        if !force, case let .loaded(date) = state, Date().timeIntervalSince(date) < Self.refreshInterval { return }
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
            status == 404 ? "No extensions for this version (\(ref))." : "GitHub answered \(status)."
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
        let personal = ["yaml", "yml"].map { store.directoryURL.appendingPathComponent("\(entry.id).\($0)") }
        if store.entry(id: entry.id) != nil || fm.fileExists(atPath: destination.path) || personal
            .contains(where: { fm.fileExists(atPath: $0.path) })
        {
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

    /// One of `entry`'s screenshots, fetched the first time it is shown and
    /// kept for the run; nil when it can't be.
    func screenshot(_ path: String, of entry: Entry) async -> Data? {
        let url = Self.fileURL(ref: ref, id: entry.id, path: path)
        if let data = images[url] { return data }
        guard let (data, status) = try? await fetch(url), status == 200 else { return nil }
        images[url] = data
        return data
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
    case installed(CustomPaletteStore.Entry, registry: PaletteRegistry.Entry?)
    case available(PaletteRegistry.Entry)

    var id: String {
        switch self {
        case let .installed(entry, _): "installed:\(entry.id)"
        case let .available(entry): "available:\(entry.id)"
        }
    }

    /// The extension's id, installed or not.
    var extensionID: String {
        switch self {
        case let .installed(entry, _): entry.id
        case let .available(entry): entry.id
        }
    }

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }

    var title: String {
        switch self {
        case let .installed(entry, _): entry.pill.title
        case let .available(entry): entry.name
        }
    }

    var summary: String {
        switch self {
        case let .installed(entry, _): entry.failure?.localizedDescription ?? entry.description
            ?? (entry.extensionDirectory ?? entry.fileURL).lastPathComponent
        case let .available(entry): entry.failure.map { "Can't be read by this version: \($0.localizedDescription)" }
            ?? entry.description ?? entry.readme.flatMap(MactermExtension.summary(readme:)) ?? ""
        }
    }

    var icon: String {
        switch self {
        case let .installed(entry, _): entry.pill.systemImage
        case let .available(entry): entry.icon
        }
    }

    /// Who maintains it: an extension's `authors:`; none for a palette file
    /// of the user's own.
    var authors: [String] {
        switch self {
        case let .installed(entry, _): entry.authors
        case let .available(entry): entry.authors
        }
    }

    /// Every extension in one list — installed and not, the installed ones
    /// once each — by name, or ranked by `query` (the app's one search, as
    /// every Settings list).
    static func items(
        installed: [CustomPaletteStore.Entry],
        registry: [PaletteRegistry.Entry],
        query: String
    ) -> [ExtensionGalleryItem] {
        let installedIDs = Set(installed.map(\.id))
        let byID = Dictionary(registry.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let all: [ExtensionGalleryItem] = installed.map { .installed($0, registry: byID[$0.id]) }
            + registry.filter { !installedIDs.contains($0.id) }.map { .available($0) }
        let sorted = all.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return Search.rank(sorted, by: query) { [$0.title, $0.summary] }
    }

    static func == (lhs: ExtensionGalleryItem, rhs: ExtensionGalleryItem) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.summary == rhs.summary
    }
}
