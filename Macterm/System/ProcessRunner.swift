import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ProcessRunner")

/// Runs a short process to its exit and collects its output. Shared by the
/// Git reads of Project Insights and the ssh commands over a host's master
/// (`SSHConnections`).
enum ProcessRunner {
    /// How long after the process exits its output is still read.
    static let drainTimeout: Duration = .seconds(1)

    struct Outcome {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    /// Run a process to its exit, bounded by `timeout`, and collect both
    /// streams. nil when it cannot start.
    ///
    /// Each pipe is read as data arrives, never with `readDataToEndOfFile`:
    /// the handler reports EOF with no data once the child's end closes,
    /// and every byte the child wrote is collected by then. The wait for
    /// EOF after the exit is bounded by `drainTimeout`, because a child of
    /// the process (a daemon git starts, a child of ssh) could keep a pipe
    /// open after the process exited.
    static func run(
        _ executable: String, _ arguments: [String], environment: [String: String], timeout: Duration
    ) async -> Outcome? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let stdout = CollectedPipe()
        let stderr = CollectedPipe()
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe
        let exited = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            exited.continuation.yield(process.terminationStatus)
            exited.continuation.finish()
        }
        do {
            try process.run()
        } catch {
            stdout.stop()
            stderr.stop()
            logger.error("cannot run \(executable, privacy: .public): \(EnglishErrorText.describe(error), privacy: .public)")
            return nil
        }
        let killer = Task {
            try? await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        var status: Int32 = -1
        for await code in exited.stream {
            status = code
        }
        killer.cancel()
        await stdout.finish(within: drainTimeout)
        await stderr.finish(within: drainTimeout)
        return Outcome(status: status, stdout: stdout.text, stderr: stderr.text)
    }
}

/// A pipe whose readability handler collects the bytes on its own thread
/// and reports EOF.
final class CollectedPipe: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var storage = Data()
    private let eof = AsyncStream<Void>.makeStream()

    init() {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                self?.eof.continuation.finish()
            } else {
                self?.append(data)
            }
        }
    }

    private func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    /// Wait for EOF, at most `limit`, then stop reading.
    func finish(within limit: Duration) async {
        let drain = Task { [eof] in
            try? await Task.sleep(for: limit)
            eof.continuation.finish()
        }
        for await _ in eof.stream {}
        drain.cancel()
        stop()
    }

    func stop() {
        pipe.fileHandleForReading.readabilityHandler = nil
    }

    /// Read on, and drop what comes: for a process that runs on after its
    /// output stops counting, so that a full pipe never blocks its writes.
    func discard() {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: storage, as: UTF8.self)
    }
}
