import CryptoKit
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "RemoteZmxInstall")

/// What the install sheet was opened for: a remote project path, and the
/// project when one exists (its `zmxPath` is what the check runs, and what
/// the install sets when the binary it put on the host is not the one the
/// pane would find).
struct ZmxInstallRequest: Identifiable, Equatable {
    let id = UUID()
    /// The remote project path, `[user@]host:dir`.
    let path: String
    let projectID: UUID?
    let zmxPath: String?

    /// The host, for the title: `user@host` or `host`.
    var hostName: String {
        guard case let .remote(user, host, _) = ProjectPath.parse(path) else { return path }
        return RemoteSpawn.destination(user: user, host: host)
    }
}

/// Why an install stopped.
enum ZmxInstallError: Error, Equatable {
    /// This Macterm build carries no release file (`scripts/setup.sh` writes
    /// it), so nothing can be checked before it goes over ssh.
    case noRelease
    /// The release has no checksum for the asset, so the download cannot
    /// be checked: a release from before the Linux assets.
    case noChecksum(ZmxHostTarget)
    case download(String)
    case checksumMismatch
    case extract
    case noBundledBinary

    var message: String {
        switch self {
        case .noRelease:
            String(localized: "This build of Macterm carries no zmx release to install.")
        case let .noChecksum(target):
            String(localized: "Macterm's zmx release has no build for \(target.displayName).")
        case let .download(reason):
            String(localized: "The download failed: \(reason)")
        case .checksumMismatch:
            String(localized: "The downloaded file does not match the checksum of the release.")
        case .extract:
            String(localized: "The downloaded archive could not be unpacked.")
        case .noBundledBinary:
            String(localized: "The zmx in this Macterm bundle is missing.")
        }
    }
}

/// Gets the binary for a host target: the bundled zmx for macOS, else the
/// release asset, downloaded once per release and checked against its
/// SHA-256 before anything goes over ssh. The host needs no internet.
@MainActor
struct ZmxBinaryProvider {
    var cacheDirectory: URL = FileStorage.appSupportDirectory().appendingPathComponent("zmx-downloads", isDirectory: true)
    var bundledBinary: URL? = Bundle.main.url(forResource: "zmx", withExtension: nil, subdirectory: "zmx")
    /// The bytes at a URL. Injected so a test serves a file.
    var fetch: @Sendable (URL) async throws -> Data = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw ZmxInstallError.download("HTTP \(http.statusCode)")
        }
        return data
    }

    /// The path of a `zmx` for `target`, ready to upload.
    func binary(for target: ZmxHostTarget, release: ZmxRelease) async throws -> URL {
        if target == .macOS {
            guard let bundledBinary, FileManager.default.isExecutableFile(atPath: bundledBinary.path) else {
                throw ZmxInstallError.noBundledBinary
            }
            return bundledBinary
        }
        let directory = cacheDirectory.appendingPathComponent(release.tag, isDirectory: true)
        let cached = directory.appendingPathComponent("zmx-\(target.rawValue)")
        if FileManager.default.isExecutableFile(atPath: cached.path) { return cached }
        guard let expected = release.sha256(for: target) else { throw ZmxInstallError.noChecksum(target) }
        guard let url = release.downloadURL(for: target) else { throw ZmxInstallError.download("no URL") }

        let data: Data
        do {
            data = try await fetch(url)
        } catch let error as ZmxInstallError {
            throw error
        } catch {
            throw ZmxInstallError.download(EnglishErrorText.describe(error))
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else {
            logger.error("""
            zmx asset \(release.assetName(for: target), privacy: .public) hashed \(digest, privacy: .public), \
            release says \(expected, privacy: .public)
            """)
            throw ZmxInstallError.checksumMismatch
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let archive = directory.appendingPathComponent(release.assetName(for: target))
        try data.write(to: archive, options: .atomic)
        defer { try? FileManager.default.removeItem(at: archive) }
        let unpacked = try Self.unpack(archive, into: directory)
        try? FileManager.default.removeItem(at: cached)
        try FileManager.default.moveItem(at: unpacked, to: cached)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cached.path)
        return cached
    }

    /// The `zmx` inside the release tarball, unpacked next to it.
    private static func unpack(_ archive: URL, into directory: URL) throws -> URL {
        let scratch = directory.appendingPathComponent("unpack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", scratch.path, "zmx"]
        tar.standardOutput = FileHandle.nullDevice
        tar.standardError = FileHandle.nullDevice
        try tar.run()
        tar.waitUntilExit()
        let binary = scratch.appendingPathComponent("zmx")
        guard tar.terminationStatus == 0, FileManager.default.fileExists(atPath: binary.path) else {
            throw ZmxInstallError.extract
        }
        let kept = directory.appendingPathComponent("zmx-unpacked-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: binary, to: kept)
        return kept
    }
}

/// One install of the fork on a host, as the sheet shows it (#699): the
/// check of the host, the verdict, then the download, the upload and the
/// move into place, each ssh under a pty so the host may ask (`TTYCommand`,
/// `SSHPrompt`). Nothing runs by itself: `check` runs when the sheet opens,
/// `install` when the user clicks.
@MainActor @Observable
final class RemoteZmxInstallFlow {
    enum Phase: Equatable {
        case checking
        case checked
        case downloading
        case uploading
        case installing
        case done
        case failed
    }

    let request: ZmxInstallRequest
    let release: ZmxRelease?
    private let remote: ProjectPath?
    private(set) var phase: Phase = .checking
    private(set) var hostState: ZmxHostState?
    private(set) var verdict: ZmxInstallVerdict?
    /// Everything the connections printed, for the sheet. A secret the user
    /// typed at a prompt is never in it.
    private(set) var log = ""
    /// The prompt the current connection waits on, nil while none.
    private(set) var prompt: SSHPrompt?
    private(set) var failure: String?
    private(set) var installedPath: String?
    private(set) var installedVersion: ZmxVersion?

    /// How a step runs: the real one starts a `TTYCommand`; a test hands in
    /// a fake that returns a status and feeds output.
    typealias StepRunner = @MainActor (_ argv: [String], _ onOutput: @escaping @MainActor (String) -> Void) async -> Int32
    @ObservationIgnored private let customRunner: StepRunner?
    @ObservationIgnored private let binaries: ZmxBinaryProvider
    @ObservationIgnored private var command: TTYCommand?
    @ObservationIgnored private var stepOutput = ""
    @ObservationIgnored private var cancelled = false

    init(
        request: ZmxInstallRequest,
        release: ZmxRelease? = .bundled,
        binaries: ZmxBinaryProvider = ZmxBinaryProvider(),
        runner: StepRunner? = nil
    ) {
        self.request = request
        self.release = release
        self.binaries = binaries
        remote = ProjectPath.remote(from: request.path)
        customRunner = runner
    }

    /// The real step: a `TTYCommand`, kept so a prompt can be answered.
    private func runWithTTY(_ argv: [String], onOutput: @escaping @MainActor (String) -> Void) async -> Int32 {
        let command = TTYCommand()
        self.command = command
        do {
            try command.start(argv: argv, onOutput: onOutput)
        } catch {
            logger.error("could not start \(argv.first ?? "", privacy: .public): \(EnglishErrorText.describe(error), privacy: .public)")
            return 127
        }
        return await command.waitForExit()
    }

    /// What the sheet offers after the check: nil before it, or when the
    /// host runs the pinned build, has no build, or the release has no
    /// asset for it.
    var offer: ZmxInstallVerdict.Offer? {
        guard phase == .checked, let verdict, let offer = verdict.offer, let release, let target = hostState?.target else { return nil }
        guard target == .macOS || release.sha256(for: target) != nil else { return nil }
        return offer
    }

    /// After a success: the binary the pane would run is not the one the
    /// install put on the host (another zmx comes first in PATH, or the
    /// project names one), so the project's `zmxPath` should be set.
    var installedPathDiffersFromProjectZmx: Bool {
        guard let installedPath else { return false }
        return hostState?.zmxPath != installedPath
    }

    /// Asks the host what it is and which zmx it runs.
    func check() async {
        phase = .checking
        failure = nil
        guard let remote, let argv = RemoteSpawn.zmxHostCheckArgv(remote: remote, zmxPath: request.zmxPath) else {
            fail(String(localized: "The project path is not a remote path."))
            return
        }
        let status = await run(argv)
        guard !cancelled else { return }
        guard status == 0, let state = ZmxHostState.parse(stepOutput) else {
            fail(String(localized: "The host did not answer the check. See the connection's output below."))
            return
        }
        hostState = state
        verdict = ZmxInstallVerdict.decide(state: state, pinnedTag: release?.tag ?? "")
        phase = .checked
    }

    /// Downloads (or takes the bundled) binary, uploads it, moves it into
    /// place and reads the installed version back.
    func install() async {
        guard let remote, let state = hostState, let target = state.target else { return }
        guard let release else {
            fail(ZmxInstallError.noRelease.message)
            return
        }
        failure = nil
        phase = .downloading
        let binary: URL
        do {
            binary = try await binaries.binary(for: target, release: release)
        } catch let error as ZmxInstallError {
            fail(error.message)
            return
        } catch {
            fail(EnglishErrorText.describe(error))
            return
        }
        guard !cancelled else { return }

        phase = .uploading
        guard let upload = RemoteSpawn.zmxUploadArgv(remote: remote, localPath: binary.path) else { return }
        let uploadStatus = await run(upload)
        guard !cancelled else { return }
        guard uploadStatus == 0 else {
            fail(String(localized: "The upload failed (scp exited with \(uploadStatus))."))
            return
        }

        phase = .installing
        guard let install = RemoteSpawn.zmxInstallArgv(remote: remote) else { return }
        let installStatus = await run(install)
        guard !cancelled else { return }
        let installed = stepOutput.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("installed=") }
            .map { String($0.dropFirst("installed=".count)).trimmingCharacters(in: .whitespaces) }
        guard installStatus == 0, let installed, !installed.isEmpty else {
            fail(String(localized: "The install on the host failed (ssh exited with \(installStatus))."))
            return
        }
        installedPath = installed
        installedVersion = stepOutput.split(whereSeparator: \.isNewline).last.flatMap { ZmxVersion.parse(String($0)) }
        phase = .done
        logger
            .info(
                """
                installed zmx \(self.installedVersion?.forkTag ?? "?", privacy: .public) \
                at \(installed, privacy: .public) on \(self.request.hostName, privacy: .public)
                """
            )
    }

    /// Answers the prompt the connection waits on. The text goes to the
    /// program's tty and nowhere else.
    func answerPrompt(_ text: String) {
        guard let asked = prompt else { return }
        prompt = nil
        guard case .secret = asked else {
            command?.write(text)
            return
        }
        // A secret goes only to a terminal that does not echo it.
        guard let command else { return }
        Task { [weak self] in
            guard await command.writeSecret(text) else {
                logger.warning("a secret prompt kept echo on; nothing was sent")
                self?.prompt = asked
                return
            }
        }
    }

    /// Stops whatever runs. The sheet closes after it.
    func cancel() {
        cancelled = true
        command?.terminate()
    }

    private func run(_ argv: [String]) async -> Int32 {
        stepOutput = ""
        prompt = nil
        log += (log.isEmpty ? "" : "\n") + "$ " + Self.describe(argv) + "\n"
        let logStart = log.count
        let onOutput: @MainActor (String) -> Void = { [weak self] output in
            guard let self else { return }
            stepOutput = output
            log = String(log.prefix(logStart)) + output
            prompt = SSHPrompt.detect(in: output)
        }
        let status: Int32 = if let customRunner {
            await customRunner(argv, onOutput)
        } else {
            await runWithTTY(argv, onOutput: onOutput)
        }
        prompt = nil
        command = nil
        return status
    }

    /// The command line for the log: the remote script is long, so only
    /// the program and the host.
    private static func describe(_ argv: [String]) -> String {
        guard let program = argv.first else { return "" }
        let host = argv.dropFirst()
            .first { !$0.hasPrefix("-") && !$0.hasPrefix("ConnectTimeout") && !$0.contains(" ") && !$0.hasPrefix("/") }
        return [program, host].compactMap(\.self).joined(separator: " ")
    }

    private func fail(_ message: String) {
        failure = message
        phase = .failed
        logger.warning("install of zmx on \(self.request.hostName, privacy: .public) stopped: \(message, privacy: .public)")
    }
}
