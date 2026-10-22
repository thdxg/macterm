import Foundation
import ImageIO

/// Runs `macterm-icon-renderer` (Contents/Helpers) for one
/// `AdaptiveIconRequest` and returns its PNG.
///
/// The helper calls Apple's private icon renderer, so everything here assumes
/// it can fail in any way: absent, unable to launch (a symbol that a macOS
/// update removed stops it in dyld), killed by a trap, hung, or answering
/// with bytes that are no image. Each of those is a `Failure`, never a throw
/// past the caller and never a crash: the request travels as an argument, so
/// the app writes to no pipe that a dead helper could close (an unignored
/// SIGPIPE stops the app), and a run that outlives `timeout` is killed.
enum AdaptiveIconRenderer {
    enum Failure: Error, Equatable {
        case helperMissing
        case launchFailed(String)
        case timedOut
        case killed(signal: Int32)
        case exited(code: Int32, message: String)
        case notAnImage

        /// One line for the log, in English (`EnglishErrorText`).
        var description: String {
            switch self {
            case .helperMissing: "the helper is not in the bundle"
            case let .launchFailed(reason): "the helper did not launch: \(reason)"
            case .timedOut: "the helper did not finish in time"
            case let .killed(signal): "the helper stopped on signal \(signal)"
            case let .exited(code, message): "the helper exited with \(code): \(message)"
            case .notAnImage: "the helper's output is not an image"
            }
        }
    }

    /// Where the app bundle keeps the helper.
    static var bundledHelperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/macterm-icon-renderer")
    }

    /// A render takes about 0.25 s, most of it the helper's launch and GPU
    /// setup. Ten seconds is far beyond any working run.
    static let timeout: TimeInterval = 10

    /// Render off the main thread. The PNG is checked to decode, so a
    /// success is always an image the presenter can install.
    static func render(
        _ request: AdaptiveIconRequest,
        helper: URL = bundledHelperURL,
        timeout: TimeInterval = timeout
    ) async -> Result<Data, Failure> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: run(request, helper: helper, timeout: timeout))
            }
        }
    }

    private static func run(_ request: AdaptiveIconRequest, helper: URL, timeout: TimeInterval) -> Result<Data, Failure> {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { return .failure(.helperMissing) }
        guard let json = try? JSONEncoder().encode(request), let argument = String(data: json, encoding: .utf8) else {
            return .failure(.launchFailed("the request does not encode"))
        }

        let process = Process()
        process.executableURL = helper
        process.arguments = [argument]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(EnglishErrorText.describe(error)))
        }

        let deadline = Deadline()
        let kill = DispatchWorkItem {
            deadline.markPassed()
            process.terminate()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: kill)

        // Drain stderr beside stdout: a helper that fills one pipe while the
        // app waits on the other would never finish.
        let errorText = DrainedText()
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            errorText.set(errors.fileHandleForReading.readDataToEndOfFile())
            drained.leave()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()
        kill.cancel()

        if deadline.passed { return .failure(.timedOut) }
        if process.terminationReason == .uncaughtSignal {
            return .failure(.killed(signal: process.terminationStatus))
        }
        guard process.terminationStatus == AdaptiveIconRenderExit.ok.rawValue else {
            return .failure(.exited(code: process.terminationStatus, message: errorText.text))
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else { return .failure(.notAnImage) }
        return .success(data)
    }

    /// Whether the kill timer fired, read after the process has exited.
    private final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private var didPass = false
        var passed: Bool { lock.withLock { didPass } }
        func markPassed() {
            lock.withLock { didPass = true }
        }
    }

    private final class DrainedText: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        var text: String {
            lock.withLock { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        func set(_ newData: Data) {
            lock.withLock { data = newData }
        }
    }
}
