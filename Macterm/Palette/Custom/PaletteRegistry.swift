import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "PaletteRegistry")

/// The palettes anyone can install (`palettes/` in Macterm's repository),
/// read from GitHub for Settings → Palettes. Read at the version this build
/// came from (`ref(bundleID:version:)`), so the gallery offers only palettes
/// written for it, and each file is run through this build's validator: one
/// it can't read is shown with why, and can't be installed.
///
/// Fetched when Settings → Palettes opens, at most once an hour
/// (`refreshInterval`), or on Refresh — never in the background. Installing
/// copies the file into `~/.config/macterm/palettes/`; nothing here runs a
/// palette's commands.
@MainActor @Observable
final class PaletteRegistry {
    struct Entry: Identifiable, Equatable {
        /// The file's name without `.yaml`: the installed palette's id.
        let id: String
        /// The file, as installed.
        let text: String
        /// The palette as this build reads it, or why it can't.
        let result: Result<CustomPalette, CustomPaletteError>
        let header: CustomPaletteHeader?

        var palette: CustomPalette? { try? result.get() }
        var failure: CustomPaletteError? {
            if case let .failure(error) = result { return error }
            return nil
        }

        var name: String { palette?.name ?? header?.name ?? id }
        var icon: String { palette?.icon ?? header?.icon ?? CustomPalette.defaultIcon }
        var description: String? { palette?.description ?? header?.description }

        init(id: String, text: String) {
            self.id = id
            self.text = text
            header = CustomPaletteFile.parseHeader(yaml: text)
            do {
                result = try .success(CustomPalette(file: CustomPaletteFile.parse(yaml: text), id: id))
            } catch let error as CustomPaletteError {
                result = .failure(error)
            } catch {
                result = .failure(.parse(underlying: error))
            }
        }
    }

    enum State: Equatable {
        case idle
        case loading
        case loaded(Date)
        case failed(String)
    }

    /// Fetches a URL: its body and HTTP status. Injected so tests serve the
    /// listing and files from memory.
    typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    nonisolated static let refreshInterval: TimeInterval = 3600
    nonisolated static let repository = "thdxg/macterm"

    /// The repository's ref this build reads: a debug build `main`, a tip
    /// build the rolling `tip` tag, a release or beta its own `v<version>`.
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

    /// This build's ref. A debug build can read another with
    /// `MACTERM_PALETTE_REF` — a branch whose palettes aren't on `main` yet.
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

    nonisolated static func listingURL(ref: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/repos/\(repository)/contents/palettes"
        components.queryItems = [URLQueryItem(name: "ref", value: ref)]
        // Every part is fixed but the ref, which `URLQueryItem` escapes.
        return components.url ?? URL(fileURLWithPath: "/")
    }

    /// The `.yaml` files in a GitHub contents listing, by id, with where to
    /// download each.
    nonisolated static func parseListing(_ data: Data) throws -> [(id: String, url: URL)] {
        struct Item: Decodable {
            let name: String
            let type: String
            let download_url: URL?
        }
        return try JSONDecoder().decode([Item].self, from: data)
            .filter { $0.type == "file" && $0.name.hasSuffix(".yaml") }
            .compactMap { item in item.download_url.map { (String(item.name.dropLast(".yaml".count)), $0) } }
            .sorted { $0.id < $1.id }
    }

    /// Reads the repository's palettes unless they were read within the
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
                let (listing, status) = try await fetch(Self.listingURL(ref: ref))
                guard status == 200 else { throw RegistryError(status: status, ref: ref) }
                let files = try Self.parseListing(listing)
                let texts = try await withThrowingTaskGroup(of: (String, String).self) { group in
                    for file in files {
                        group.addTask {
                            let (data, status) = try await fetch(file.url)
                            guard status == 200 else { throw RegistryError(status: status, ref: ref) }
                            return (file.id, String(decoding: data, as: UTF8.self))
                        }
                    }
                    var texts: [String: String] = [:]
                    for try await (id, text) in group {
                        texts[id] = text
                    }
                    return texts
                }
                outcome = .success(texts.keys.sorted().map { Entry(id: $0, text: texts[$0] ?? "") })
            } catch {
                outcome = .failure(error)
            }
            guard let self, !Task.isCancelled else { return }
            switch outcome {
            case let .success(entries):
                self.entries = entries
                state = .loaded(Date())
            case let .failure(error):
                logger.error("palette registry: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    struct RegistryError: LocalizedError {
        let status: Int
        let ref: String
        var errorDescription: String? {
            status == 404 ? "No palettes for this version (\(ref))." : "GitHub answered \(status)."
        }
    }

    enum InstallError: LocalizedError, Equatable {
        case alreadyInstalled(String)
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case let .alreadyInstalled(file): "\(file) is already in your palettes folder."
            case let .unreadable(reason): "This version of Macterm can't read it: \(reason)"
            }
        }
    }

    /// Copies `entry` into `store`'s folder as `<id>.yaml` and reloads the
    /// store, so it is installed at once. Never overwrites: a file of that
    /// name, `.yaml` or `.yml`, is the user's.
    @discardableResult
    func install(_ entry: Entry, into store: CustomPaletteStore) throws -> URL {
        if let failure = entry.failure { throw InstallError.unreadable(failure.localizedDescription) }
        let fm = FileManager.default
        for ext in ["yaml", "yml"] {
            let existing = store.directoryURL.appendingPathComponent("\(entry.id).\(ext)")
            if fm.fileExists(atPath: existing.path) { throw InstallError.alreadyInstalled(existing.lastPathComponent) }
        }
        try fm.createDirectory(at: store.directoryURL, withIntermediateDirectories: true)
        let url = store.directoryURL.appendingPathComponent("\(entry.id).yaml")
        try Data(entry.text.utf8).write(to: url, options: .withoutOverwriting)
        store.reload()
        return url
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

/// One card in Settings → Palettes: a built-in screen, an installed custom
/// palette, or one from the repository that isn't installed.
enum PaletteGalleryItem: Identifiable, Equatable {
    case builtIn(PaletteScopeID)
    /// `registry` is the repository's entry of the same id, when there is one.
    case installed(CustomPaletteStore.Entry, registry: PaletteRegistry.Entry?)
    case available(PaletteRegistry.Entry)

    var id: String {
        switch self {
        case let .builtIn(scope): "builtin:\(scope.settingsID)"
        case let .installed(entry, _): "installed:\(entry.id)"
        case let .available(entry): "available:\(entry.id)"
        }
    }

    var title: String {
        switch self {
        case let .builtIn(scope): scope.pill.title
        case let .installed(entry, _): entry.pill.title
        case let .available(entry): entry.name
        }
    }

    var summary: String {
        switch self {
        case let .builtIn(scope): scope.summary
        case let .installed(entry, _): entry.failure?.localizedDescription ?? entry.description ?? entry.fileURL.lastPathComponent
        case let .available(entry): entry.failure.map { "Needs a newer Macterm: \($0.localizedDescription)" } ?? entry.description ?? ""
        }
    }

    var icon: String {
        switch self {
        case let .builtIn(scope): scope.pill.systemImage
        case let .installed(entry, _): entry.pill.systemImage
        case let .available(entry): entry.icon
        }
    }

    /// The gallery's sections, in order, each ranked by `query` (the app's
    /// one search, as every Settings list): built-in screens, installed
    /// palettes, then the repository's not yet installed. A repository
    /// palette already installed — same id — is listed once, as installed.
    static func sections(
        builtIn: [PaletteScopeID],
        installed: [CustomPaletteStore.Entry],
        registry: [PaletteRegistry.Entry],
        query: String
    ) -> [(title: String, items: [PaletteGalleryItem])] {
        let installedIDs = Set(installed.map(\.id))
        let byID = Dictionary(registry.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups: [(String, [PaletteGalleryItem])] = [
            ("Built-in", builtIn.map { .builtIn($0) }),
            ("Installed", installed.map { .installed($0, registry: byID[$0.id]) }),
            ("Available", registry.filter { !installedIDs.contains($0.id) }.map { .available($0) }),
        ]
        return groups.map { title, items in
            (title, Search.rank(items, by: query) { [$0.title, $0.summary] })
        }
    }

    static func == (lhs: PaletteGalleryItem, rhs: PaletteGalleryItem) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.summary == rhs.summary
    }
}
