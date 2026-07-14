import Foundation

/// Minimal thread-safe box so an injected `@Sendable` closure can record
/// across concurrent task groups (kill fan-outs, probe recorders).
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) {
        stored = value
    }

    var value: T { lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&stored)
    }
}
