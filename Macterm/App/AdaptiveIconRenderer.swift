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
///
/// A run ends when the helper exits, not when its pipes close: a child of the
/// helper can keep a pipe open after the helper is gone. The output is read
/// for at most `drainTimeout` after the exit, and not at all after a timeout.
/// A helper that ignores SIGTERM gets SIGKILL `killGrace` later. Nothing here
/// waits without a bound, so a hung helper never holds a thread for good.
enum AdaptiveIconRenderer {
    enum Failure: Error, Equatable {
        case helperMissing
        case launchFailed(String)
        case timedOut
        case killed(signal: Int32, message: String)
        case exited(code: Int32, message: String)
        case notAnImage
        /// A newer request replaced this one in the `Queue` before it ran.
        /// It says nothing about the helper.
        case superseded

        /// One line for the log, in English (`EnglishErrorText`).
        var description: String {
            switch self {
            case .helperMissing: "the helper is not in the bundle"
            case let .launchFailed(reason): "the helper did not launch: \(reason)"
            case .timedOut: "the helper did not finish in time"
            case let .killed(signal, message): "the helper stopped on signal \(signal)\(message.isEmpty ? "" : ": " + message)"
            case let .exited(code, message): "the helper exited with \(code): \(message)"
            case .notAnImage: "the helper's output is not an image"
            case .superseded: "a newer request replaced this one"
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
    /// How long a helper has to exit after SIGTERM before it gets SIGKILL,
    /// and how long the run then waits for the exit.
    static let killGrace: TimeInterval = 1
    /// How long the output is read after the helper exits.
    static let drainTimeout: TimeInterval = 1

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
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        // Read both pipes as data arrives: a helper that fills one pipe while
        // the app waits on the other would never finish.
        let outputData = PipeDrain(output)
        let errorData = PipeDrain(errors)
        do {
            try process.run()
        } catch {
            outputData.stop()
            errorData.stop()
            return .failure(.launchFailed(EnglishErrorText.describe(error)))
        }

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + killGrace) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + killGrace)
            }
            outputData.stop()
            errorData.stop()
            return .failure(.timedOut)
        }

        let drained = DispatchTime.now() + drainTimeout
        let data = outputData.collect(until: drained)
        let errorText = String(decoding: errorData.collect(until: drained), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationReason == .uncaughtSignal {
            return .failure(.killed(signal: process.terminationStatus, message: errorText))
        }
        guard process.terminationStatus == AdaptiveIconRenderExit.ok.rawValue else {
            return .failure(.exited(code: process.terminationStatus, message: errorText))
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        else { return .failure(.notAnImage) }
        return .success(data)
    }

    /// The bytes of one pipe, read as they arrive, so that no thread blocks
    /// on a read that a child of the helper could keep open for good.
    private final class PipeDrain: @unchecked Sendable {
        private let handle: FileHandle
        private let ended = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var data = Data()
        private var reading = true

        init(_ pipe: Pipe) {
            handle = pipe.fileHandleForReading
            handle.readabilityHandler = { [weak self] handle in
                // One read(2) of what is there. `read(upToCount:)` blocks
                // until it has the whole count or the end of the file, and
                // `availableData` raises an ObjC exception on an error.
                // 0 is the end of the file; an error ends the output too.
                var buffer = [UInt8](repeating: 0, count: 1 << 16)
                let count = read(handle.fileDescriptor, &buffer, buffer.count)
                self?.receive(count > 0 ? Data(buffer[0 ..< count]) : Data())
            }
        }

        private func receive(_ chunk: Data) {
            let atEnd: Bool = lock.withLock {
                guard reading else { return false }
                if chunk.isEmpty {
                    reading = false
                    return true
                }
                data.append(chunk)
                return false
            }
            if atEnd {
                handle.readabilityHandler = nil
                ended.signal()
            }
        }

        /// The bytes read until the end of the output or `deadline`,
        /// whichever comes first.
        func collect(until deadline: DispatchTime) -> Data {
            _ = ended.wait(timeout: deadline)
            stop()
            return lock.withLock { data }
        }

        /// Stops reading. The pipe closes when the last reference goes.
        func stop() {
            lock.withLock { reading = false }
            handle.readabilityHandler = nil
        }
    }
}

extension AdaptiveIconRenderer {
    /// Runs one render at a time. A request that arrives while a render
    /// runs waits, and a newer request replaces the one that waits, which
    /// ends as `.superseded`. A burst of config changes therefore starts at
    /// most two helpers, and never more than one at once.
    @MainActor
    final class Queue {
        typealias Completion = @MainActor (Result<Data, Failure>) -> Void

        private let helper: URL
        private let timeout: TimeInterval
        private var running = false
        private var waiting: (request: AdaptiveIconRequest, completion: Completion)?

        init(helper: URL = AdaptiveIconRenderer.bundledHelperURL, timeout: TimeInterval = AdaptiveIconRenderer.timeout) {
            self.helper = helper
            self.timeout = timeout
        }

        func render(_ request: AdaptiveIconRequest, completion: @escaping Completion) {
            guard running else { return start(request, completion: completion) }
            waiting?.completion(.failure(.superseded))
            waiting = (request, completion)
        }

        private func start(_ request: AdaptiveIconRequest, completion: @escaping Completion) {
            running = true
            Task {
                let result = await AdaptiveIconRenderer.render(request, helper: helper, timeout: timeout)
                completion(result)
                running = false
                if let next = waiting {
                    waiting = nil
                    start(next.request, completion: next.completion)
                }
            }
        }
    }
}
