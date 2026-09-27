import Foundation
import os
import Security

private let logger = Logger(subsystem: appBundleID, category: "PasswordStore")

/// A saved password as the list shows it — never the secret itself, which is
/// read from the store only at the moment it is typed or copied.
struct SavedPassword: Identifiable, Hashable {
    let id: PasswordEntryID
    let modified: Date?
}

enum PasswordStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "Keychain: \(message)"
        }
    }
}

protocol PasswordStoring: Sendable {
    func list() throws -> [SavedPassword]
    func password(for id: PasswordEntryID) throws -> String?
    func save(_ password: String, for id: PasswordEntryID) throws
    func delete(_ id: PasswordEntryID) throws
}

/// Generic-password items in the user's login keychain, one per entry, under
/// a service of their own.
///
/// The login (file-based) keychain, not the data-protection one: that needs a
/// `keychain-access-groups` entitlement backed by a provisioning profile, which
/// a self-signed app can't have. So there is no per-item biometric access
/// control; Touch ID is the app's own gate in front of every read
/// (`PasswordAuthenticator`). The item ACL trusts the app's code signature, so
/// the release certificate being stable is what keeps updates from prompting
/// — an ad-hoc debug build is a new identity per build and gets the system's
/// "wants to use your confidential information" dialog on a read.
///
/// Listing asks for attributes only, which never prompts; each entry's
/// command and prompt ride in `kSecAttrGeneric` as JSON, so the account string
/// is display-only and never parsed.
struct KeychainPasswordStore: PasswordStoring {
    let service: String

    static var defaultService: String { "\(appBundleID).passwords" }

    private struct Metadata: Codable {
        let command: String?
        let prompt: String
    }

    private func baseQuery(_ id: PasswordEntryID? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let id { query[kSecAttrAccount as String] = id.account }
        return query
    }

    func list() throws -> [SavedPassword] {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw PasswordStoreError.keychain(status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let data = item[kSecAttrGeneric as String] as? Data,
                  let meta = try? JSONDecoder().decode(Metadata.self, from: data)
            else { return nil }
            return SavedPassword(
                id: PasswordEntryID(command: meta.command, prompt: meta.prompt),
                modified: item[kSecAttrModificationDate as String] as? Date
            )
        }
    }

    func password(for id: PasswordEntryID) throws -> String? {
        var query = baseQuery(id)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw PasswordStoreError.keychain(status) }
        return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    func save(_ password: String, for id: PasswordEntryID) throws {
        let secret = Data(password.utf8)
        let meta = try JSONEncoder().encode(Metadata(command: id.command, prompt: id.prompt))
        let attributes: [String: Any] = [
            kSecValueData as String: secret,
            kSecAttrGeneric as String: meta,
            kSecAttrLabel as String: "Macterm: \(id.title)",
            kSecAttrDescription as String: "Macterm terminal password",
        ]
        let update = SecItemUpdate(baseQuery(id) as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw PasswordStoreError.keychain(update) }
        let add = baseQuery(id).merging(attributes) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw PasswordStoreError.keychain(status) }
    }

    func delete(_ id: PasswordEntryID) throws {
        let status = SecItemDelete(baseQuery(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PasswordStoreError.keychain(status)
        }
    }
}

/// The store tests and the hermetic harnesses use: those launches must never
/// read or write the developer's real login keychain.
final class InMemoryPasswordStore: PasswordStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PasswordEntryID: (password: String, modified: Date)] = [:]

    func list() throws -> [SavedPassword] {
        lock.withLock { items.map { SavedPassword(id: $0.key, modified: $0.value.modified) } }
    }

    func password(for id: PasswordEntryID) throws -> String? {
        lock.withLock { items[id]?.password }
    }

    func save(_ password: String, for id: PasswordEntryID) throws {
        lock.withLock { items[id] = (password, Date()) }
    }

    func delete(_ id: PasswordEntryID) throws {
        _ = lock.withLock { items.removeValue(forKey: id) }
    }
}

/// The app's view of the saved passwords: the list (for "is one saved?" and
/// Settings), plus the reads and writes, all through one injectable store.
@MainActor
@Observable
final class PasswordVault {
    static let shared = PasswordVault(store: PasswordVault.defaultStore())

    private(set) var entries: [SavedPassword] = []
    /// The last store failure, shown by Settings. Cleared by a good reload.
    private(set) var lastError: String?

    @ObservationIgnored
    private let store: PasswordStoring

    init(store: PasswordStoring) {
        self.store = store
        reload()
    }

    /// Tests, the benchmark, and any launch pointed at a throwaway data dir
    /// (`MACTERM_BENCHMARK_DATA_DIR` — the e2e harness and hand-run hermetic
    /// instances) keep passwords in memory, never in the developer's keychain.
    private static func defaultStore() -> PasswordStoring {
        let env = ProcessInfo.processInfo.environment
        let hermetic = Preferences.isTestRun
            || env["MACTERM_BENCHMARK"] == "1"
            || env["MACTERM_BENCHMARK_DATA_DIR"] != nil
        return hermetic ? InMemoryPasswordStore() : KeychainPasswordStore(service: KeychainPasswordStore.defaultService)
    }

    func reload() {
        do {
            entries = try store.list().sorted { $0.id.title.localizedStandardCompare($1.id.title) == .orderedAscending }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            logger.error("list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func contains(_ id: PasswordEntryID) -> Bool {
        entries.contains { $0.id == id }
    }

    func password(for id: PasswordEntryID) -> String? {
        do {
            return try store.password(for: id)
        } catch {
            lastError = error.localizedDescription
            logger.error("read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @discardableResult
    func save(_ password: String, for id: PasswordEntryID) -> Bool {
        defer { reload() }
        do {
            try store.save(password, for: id)
            logger.info("saved password entry")
            return true
        } catch {
            lastError = error.localizedDescription
            logger.error("save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func remove(_ id: PasswordEntryID) {
        defer { reload() }
        do {
            try store.delete(id)
        } catch {
            lastError = error.localizedDescription
            logger.error("delete failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Entries whose command or prompt contains every word of `query`,
    /// case- and diacritic-insensitively — the Settings search field.
    func entries(matching query: String) -> [SavedPassword] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = "\(entry.id.command ?? "") \(entry.id.prompt)"
            return words.allSatisfy { haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}
