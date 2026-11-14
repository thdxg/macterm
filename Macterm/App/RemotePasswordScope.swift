import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "RemotePasswordScope")

/// The ssh destination as the Mac resolves it (`ssh -G`: `user@hostname:port`)
/// for each destination a remote pane names. A saved password from a host is
/// filed under it (design/006 section 6), so a host's prompt never matches an
/// entry of this Mac or of another host. ssh checks the host key for that
/// name, so a host cannot claim to be another one.
@MainActor
enum RemotePasswordScope {
    /// A failed lookup is not tried again before this long.
    static let retryAfter: TimeInterval = 30
    /// A resolved destination is read again after this long, because the ssh
    /// config can change while Macterm runs. Until then the pane has no scope.
    static let lifetime: TimeInterval = 60

    private static var resolved: [String: (value: String, at: Date)] = [:]
    private static var pending = Set<String>()
    private static var failedAt: [String: Date] = [:]

    /// The resolved destination, or nil while it resolves (the next ask has
    /// it) and after a failure. nil means: do not autofill, do not offer.
    static func scope(for destination: String) -> String? {
        if let entry = resolved[destination] {
            if Date().timeIntervalSince(entry.at) < lifetime { return entry.value }
            resolved[destination] = nil
        }
        guard !pending.contains(destination) else { return nil }
        if let failed = failedAt[destination], Date().timeIntervalSince(failed) < retryAfter { return nil }
        pending.insert(destination)
        Task { @MainActor in
            let value = await SSHConnections.shared.resolvedDestination(destination)
            pending.remove(destination)
            if let value {
                resolved[destination] = (value, Date())
            } else {
                failedAt[destination] = Date()
                logger.info("destination did not resolve: \(destination, privacy: .public)")
            }
        }
        return nil
    }
}
