import CryptoKit
import Foundation
@testable import Macterm
import Testing

@MainActor
struct RemoteZmxInstallTests {
    // MARK: - The host's target

    @Test(arguments: [
        ("Linux", "x86_64", ZmxHostTarget.linuxX86_64),
        ("Linux", "amd64", .linuxX86_64),
        ("Linux", "aarch64", .linuxAarch64),
        ("Linux", "arm64", .linuxAarch64),
        ("Linux", "ARM64", .linuxAarch64),
        ("Darwin", "arm64", .macOS),
        ("Darwin", "x86_64", .macOS),
    ])
    func a_known_host_maps_to_its_asset(system: String, machine: String, target: ZmxHostTarget) {
        #expect(ZmxHostTarget.detect(system: system + "\n", machine: machine + "\n") == target)
    }

    @Test(arguments: [
        ("Linux", "i686"), ("Linux", "riscv64"), ("Linux", "armv7l"), ("FreeBSD", "amd64"), ("OpenBSD", "amd64"),
        ("", "x86_64"), ("Linux", ""),
    ])
    func a_host_with_no_build_maps_to_nothing(system: String, machine: String) {
        #expect(ZmxHostTarget.detect(system: system, machine: machine) == nil)
    }

    @Test
    func every_target_names_a_release_asset() {
        #expect(ZmxHostTarget.linuxX86_64.assetName == "zmx-x86_64-linux.tar.gz")
        #expect(ZmxHostTarget.linuxAarch64.assetName == "zmx-aarch64-linux.tar.gz")
        #expect(ZmxHostTarget.macOS.assetName == "zmx-universal-macos.tar.gz")
    }

    // MARK: - zmx version

    @Test
    func a_fork_version_carries_its_release_tag() {
        let output = "zmx\t\t0.8.1+thdxg.build-2026-11-06-abcdef1\nghostty_vt\t1.3.2\nsocket_dir\t/tmp/zmx\n"
        #expect(ZmxVersion.parse(output) == ZmxVersion(upstream: "0.8.1", forkTag: "build-2026-11-06-abcdef1"))
        #expect(ZmxVersion.parse(output)?.isFork == true)
    }

    /// The format of the pinned 1.0.1 build's `zmx version`.
    @Test
    func a_fork_build_on_zmx_1_0_carries_its_release_tag() {
        let output = """
        zmx\t\t1.0.1+thdxg.build-2026-11-07-2d98540
        ghostty_vt\tghostty-1.4.1-dev-5UdBC-9XmgVchRr0CfxYzSRUiww0EdU1WAR3WwtMsqql
        socket_dir\t/var/folders/ld/T/zmx-501
        log_dir\t\t/Users/demo/.local/state/zmx/logs
        """
        #expect(ZmxVersion.parse(output) == ZmxVersion(upstream: "1.0.1", forkTag: "build-2026-11-07-2d98540"))
        let state = ZmxHostState(
            system: "Linux",
            machine: "x86_64",
            zmxPath: "/home/demo/.local/bin/zmx",
            version: ZmxVersion.parse(output)
        )
        #expect(ZmxInstallVerdict.decide(state: state, pinnedTag: "build-2026-11-07-2d98540") == .current(ZmxVersion(
            upstream: "1.0.1",
            forkTag: "build-2026-11-07-2d98540"
        )))
    }

    @Test
    func an_upstream_version_has_no_tag() {
        #expect(ZmxVersion.parse("zmx\t\t0.8.1\nghostty_vt\t1.3.2\n") == ZmxVersion(upstream: "0.8.1", forkTag: nil))
        #expect(ZmxVersion.parse("0.6.0") == ZmxVersion(upstream: "0.6.0", forkTag: nil))
        #expect(ZmxVersion.parse("zmx 1.0.0") == ZmxVersion(upstream: "1.0.0", forkTag: nil))
    }

    @Test(arguments: ["", "zmx", "zmx\t\t", "command not found", "zmx\t\t0.8.1 beta", "0.8.1+thdxg."])
    func anything_else_is_not_a_version(output: String) {
        #expect(ZmxVersion.parse(output) == nil)
    }

    // MARK: - The host check

    @Test
    func the_check_output_parses_into_the_host_state() {
        let state = ZmxHostState.parse("""
        system=Linux
        machine=x86_64
        path=/home/demo/.local/bin/zmx
        version=zmx\t\t0.8.1+thdxg.build-2026-11-06-abcdef1
        """)
        #expect(state == ZmxHostState(
            system: "Linux", machine: "x86_64", zmxPath: "/home/demo/.local/bin/zmx",
            version: ZmxVersion(upstream: "0.8.1", forkTag: "build-2026-11-06-abcdef1")
        ))
        #expect(state?.target == .linuxX86_64)
    }

    @Test
    func a_host_with_no_zmx_has_no_path_and_no_version() {
        let state = ZmxHostState.parse("system=Linux\nmachine=aarch64\npath=\n")
        #expect(state == ZmxHostState(system: "Linux", machine: "aarch64", zmxPath: nil, version: nil))
    }

    @Test
    func a_motd_or_a_shell_banner_does_not_confuse_the_check() {
        // Lines before the script's own, and `key=value` lines of other
        // keys, are ignored; a missing system line fails the check.
        let state = ZmxHostState
            .parse("Welcome to devbox\nLANG=C.UTF-8\nsystem=Darwin\nmachine=arm64\npath=/opt/homebrew/bin/zmx\nversion=zmx\t\t0.8.1\n")
        #expect(state?.target == .macOS)
        #expect(state?.version == ZmxVersion(upstream: "0.8.1", forkTag: nil))
        #expect(ZmxHostState.parse("Permission denied (publickey).\n") == nil)
        #expect(ZmxHostState.parse("machine=x86_64\n") == nil)
    }

    // MARK: - The verdict

    private let pinned = "build-2026-11-06-abcdef1"

    private func state(
        _ system: String = "Linux",
        _ machine: String = "x86_64",
        path: String? = "/usr/local/bin/zmx",
        version: String?
    ) -> ZmxHostState {
        ZmxHostState(system: system, machine: machine, zmxPath: path, version: version.flatMap(ZmxVersion.parse))
    }

    @Test
    func the_verdict_offers_the_right_action() {
        #expect(ZmxInstallVerdict.decide(state: state(path: nil, version: nil), pinnedTag: pinned) == .missing)
        #expect(ZmxInstallVerdict.decide(state: state(path: nil, version: nil), pinnedTag: pinned).offer == .install)

        let upstream = ZmxInstallVerdict.decide(state: state(version: "0.8.1"), pinnedTag: pinned)
        #expect(upstream == .upstream(ZmxVersion(upstream: "0.8.1", forkTag: nil)))
        #expect(upstream.offer == .update)

        let older = ZmxInstallVerdict.decide(state: state(version: "0.8.1+thdxg.build-2026-10-14-5f6a1e8"), pinnedTag: pinned)
        #expect(older == .otherBuild(ZmxVersion(upstream: "0.8.1", forkTag: "build-2026-10-14-5f6a1e8")))
        #expect(older.offer == .update)

        let current = ZmxInstallVerdict.decide(state: state(version: "0.8.1+thdxg.\(pinned)"), pinnedTag: pinned)
        #expect(current == .current(ZmxVersion(upstream: "0.8.1", forkTag: pinned)))
        #expect(current.offer == nil)

        // A zmx that did not answer `version` reads as missing: the path
        // names something that is not a zmx that runs.
        #expect(ZmxInstallVerdict.decide(state: state(version: nil), pinnedTag: pinned) == .missing)
    }

    @Test
    func an_unsupported_host_offers_nothing_whatever_it_runs() {
        let verdict = ZmxInstallVerdict.decide(state: state("FreeBSD", "amd64", version: "0.8.1"), pinnedTag: pinned)
        #expect(verdict == .unsupported(system: "FreeBSD", machine: "amd64"))
        #expect(verdict.offer == nil)
    }

    // MARK: - The bundled release

    @Test
    func the_release_file_comes_from_the_checksum_lines() {
        let release = ZmxRelease.make(tag: "build-2026-11-06-abcdef1", checksumLines: [
            "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  zmx-x86_64-linux.tar.gz",
            "FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210 *zmx-universal-macos.tar.gz",
            "not a checksum line",
            "abc  too-short.tar.gz",
        ])
        #expect(release.sha256(for: .linuxX86_64) == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        #expect(release.sha256(for: .macOS) == "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210")
        #expect(release.sha256(for: .linuxAarch64) == nil)
        #expect(release.downloadURL(for: .linuxAarch64)?.absoluteString
            == "https://github.com/thdxg/zmx/releases/download/build-2026-11-06-abcdef1/zmx-aarch64-linux.tar.gz")
    }

    @Test
    func the_release_file_round_trips_through_json() throws {
        let release = ZmxRelease(tag: "build-2026-11-06-abcdef1", assets: ["zmx-x86_64-linux.tar.gz": "00ff"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zmx-release-\(UUID().uuidString).json")
        try JSONEncoder().encode(release).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ZmxRelease.load(from: url) == release)
        #expect(ZmxRelease.load(from: url.appendingPathExtension("missing")) == nil)
    }

    // MARK: - ssh prompts

    @Test
    func a_prompt_is_the_unfinished_last_line() {
        #expect(SSHPrompt
            .detect(in: "Warning: Permanently added 'devbox' (ED25519) to the list of known hosts.\r\ndemo@devbox's password:") ==
            .secret("demo@devbox's password:"))
        #expect(SSHPrompt
            .detect(in: "Enter passphrase for key '/Users/me/.ssh/id_ed25519':") ==
            .secret("Enter passphrase for key '/Users/me/.ssh/id_ed25519':"))
        #expect(SSHPrompt.detect(in: "(demo@devbox) Password:") == .secret("(demo@devbox) Password:"))
        #expect(SSHPrompt.detect(in: "Verification code:") == .secret("Verification code:"))
        let hostKey = "The authenticity of host 'devbox (10.0.0.5)' can't be established.\r\n"
            + "ED25519 key fingerprint is SHA256:abc.\r\n"
            + "Are you sure you want to continue connecting (yes/no/[fingerprint])?"
        #expect(SSHPrompt.detect(in: hostKey) == .yesNo("Are you sure you want to continue connecting (yes/no/[fingerprint])?"))
    }

    @Test
    func a_line_that_ended_is_not_a_prompt() {
        #expect(SSHPrompt.detect(in: "demo@devbox's password:\r\n") == nil)
        #expect(SSHPrompt.detect(in: "system=Linux\nmachine=x86_64\n") == nil)
        #expect(SSHPrompt.detect(in: "installed=/home/demo/.local/bin/zmx") == nil)
        #expect(SSHPrompt.detect(in: "") == nil)
    }
}

/// The provider against a release served from a file, and the flow against
/// a fake runner: what the sheet would see at each step.
@MainActor
struct RemoteZmxInstallFlowTests {
    private let remote = "demo@devbox:~/dev/api"

    /// A tarball that holds one `zmx` (a shell script), and its SHA-256.
    private func makeAsset(in directory: URL) throws -> (data: Data, sha256: String) {
        let stage = directory.appendingPathComponent("stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let binary = stage.appendingPathComponent("zmx")
        try "#!/bin/sh\necho zmx\t\t0.8.1+thdxg.build-test\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let archive = directory.appendingPathComponent("asset.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive.path, "-C", stage.path, "zmx"]
        try tar.run()
        tar.waitUntilExit()
        let data = try Data(contentsOf: archive)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (data, sha)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zmx-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func the_provider_downloads_checks_and_unpacks_the_asset_once() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = try makeAsset(in: directory)
        let release = ZmxRelease(tag: "build-test", assets: [ZmxHostTarget.linuxX86_64.assetName: asset.sha256])
        let fetches = LockedBox(0)
        let provider = ZmxBinaryProvider(
            cacheDirectory: directory.appendingPathComponent("cache"),
            fetch: { [data = asset.data] _ in
                fetches.mutate { $0 += 1 }
                return data
            }
        )
        let binary = try await provider.binary(for: .linuxX86_64, release: release)
        #expect(FileManager.default.isExecutableFile(atPath: binary.path))
        #expect(binary.lastPathComponent == "zmx-x86_64-linux")
        #expect(fetches.value == 1)
        // The second time is the cache.
        _ = try await provider.binary(for: .linuxX86_64, release: release)
        #expect(fetches.value == 1)
        // No archive is left behind.
        let left = try FileManager.default.contentsOfDirectory(atPath: binary.deletingLastPathComponent().path)
        #expect(left == ["zmx-x86_64-linux"])
    }

    @Test
    func a_wrong_checksum_and_a_missing_one_are_refused() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = try makeAsset(in: directory)
        let provider = ZmxBinaryProvider(
            cacheDirectory: directory.appendingPathComponent("cache"),
            fetch: { [data = asset.data] _ in data }
        )
        let wrong = ZmxRelease(tag: "build-test", assets: [ZmxHostTarget.linuxX86_64.assetName: String(repeating: "0", count: 64)])
        await #expect(throws: ZmxInstallError.checksumMismatch) {
            _ = try await provider.binary(for: .linuxX86_64, release: wrong)
        }
        let none = ZmxRelease(tag: "build-test", assets: [:])
        await #expect(throws: ZmxInstallError.noChecksum(.linuxAarch64)) {
            _ = try await provider.binary(for: .linuxAarch64, release: none)
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("cache/build-test/zmx-x86_64-linux").path))
    }

    @Test
    func a_macos_host_gets_the_bundled_binary() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundled = directory.appendingPathComponent("zmx")
        try "#!/bin/sh\n".write(to: bundled, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        let provider = ZmxBinaryProvider(
            cacheDirectory: directory,
            bundledBinary: bundled,
            fetch: { _ in Issue.record("no download for macOS")
                return Data()
            }
        )
        let release = ZmxRelease(tag: "build-test", assets: [:])
        #expect(try await provider.binary(for: .macOS, release: release) == bundled)
    }

    /// A runner that answers each step from a script of outputs.
    private func scripted(_ steps: [(status: Int32, output: String)], seen: LockedBox<[[String]]>) -> RemoteZmxInstallFlow.StepRunner {
        let remaining = LockedBox(steps)
        return { argv, onOutput in
            seen.mutate { $0.append(argv) }
            var step: (status: Int32, output: String) = (1, "")
            remaining.mutate { if !$0.isEmpty { step = $0.removeFirst() } }
            onOutput(step.output)
            return step.status
        }
    }

    @Test
    func the_check_decides_the_offer_from_the_host_answer() async {
        let seen = LockedBox<[[String]]>([])
        let request = ZmxInstallRequest(path: remote, projectID: nil, zmxPath: nil)
        let release = ZmxRelease(tag: "build-test", assets: [ZmxHostTarget.linuxX86_64.assetName: String(repeating: "a", count: 64)])
        let flow = RemoteZmxInstallFlow(
            request: request, release: release,
            runner: scripted([(0, "system=Linux\nmachine=x86_64\npath=/usr/local/bin/zmx\nversion=zmx\t\t0.8.1\n")], seen: seen)
        )
        await flow.check()
        #expect(flow.phase == .checked)
        #expect(flow.offer == .update)
        #expect(flow.hostState?.target == .linuxX86_64)
        #expect(seen.value.first?.first == "ssh")
        #expect(flow.log.contains("$ ssh demo@devbox"))

        // The same host, but the release has no asset for it: nothing to offer.
        let bare = RemoteZmxInstallFlow(
            request: request, release: ZmxRelease(tag: "build-test", assets: [:]),
            runner: scripted([(0, "system=Linux\nmachine=x86_64\npath=\n")], seen: seen)
        )
        await bare.check()
        #expect(bare.verdict == .missing)
        #expect(bare.offer == nil)
    }

    @Test
    func a_host_that_does_not_answer_fails_the_check_and_keeps_the_output() async {
        let seen = LockedBox<[[String]]>([])
        let flow = RemoteZmxInstallFlow(
            request: ZmxInstallRequest(path: remote, projectID: nil, zmxPath: nil), release: nil,
            runner: scripted([(255, "demo@devbox: Permission denied (publickey).\r\n")], seen: seen)
        )
        await flow.check()
        #expect(flow.phase == .failed)
        #expect(flow.failure != nil)
        #expect(flow.log.contains("Permission denied"))
    }

    @Test
    func a_prompt_at_the_tail_of_the_output_is_offered_and_cleared() async {
        let flow = RemoteZmxInstallFlow(
            request: ZmxInstallRequest(path: remote, projectID: nil, zmxPath: nil), release: nil,
            runner: { _, onOutput in
                onOutput("demo@devbox's password:")
                return 255
            }
        )
        await flow.check()
        // The connection ended, so no prompt is left up.
        #expect(flow.prompt == nil)
        #expect(flow.phase == .failed)
    }

    @Test
    func the_install_uploads_then_moves_into_place_and_reads_the_version_back() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = try makeAsset(in: directory)
        let release = ZmxRelease(tag: "build-test", assets: [ZmxHostTarget.linuxX86_64.assetName: asset.sha256])
        let seen = LockedBox<[[String]]>([])
        let flow = RemoteZmxInstallFlow(
            request: ZmxInstallRequest(path: remote, projectID: UUID(), zmxPath: nil),
            release: release,
            binaries: ZmxBinaryProvider(
                cacheDirectory: directory.appendingPathComponent("cache"),
                fetch: { [data = asset.data] _ in data }
            ),
            runner: scripted([
                (0, "system=Linux\nmachine=x86_64\npath=/usr/local/bin/zmx\nversion=zmx\t\t0.6.0\n"),
                (0, ""),
                (0, "installed=/home/demo/.local/bin/zmx\nzmx\t\t0.8.1+thdxg.build-test\n"),
            ], seen: seen)
        )
        await flow.check()
        #expect(flow.offer == .update)
        await flow.install()
        #expect(flow.phase == .done)
        #expect(flow.installedPath == "/home/demo/.local/bin/zmx")
        #expect(flow.installedVersion == ZmxVersion(upstream: "0.8.1", forkTag: "build-test"))
        // Another zmx came first in PATH: the project should name the new one.
        #expect(flow.installedPathDiffersFromProjectZmx)
        let argv = seen.value
        #expect(argv.count == 3)
        #expect(argv[1].first == "scp")
        #expect(argv[1].contains { $0.hasSuffix("/zmx-x86_64-linux") })
        #expect(argv[1].last == "demo@devbox:.zmx.macterm")
        #expect(argv[2].first == "ssh")
    }

    @Test
    func a_failed_upload_stops_the_install() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = try makeAsset(in: directory)
        let release = ZmxRelease(tag: "build-test", assets: [ZmxHostTarget.linuxX86_64.assetName: asset.sha256])
        let seen = LockedBox<[[String]]>([])
        let flow = RemoteZmxInstallFlow(
            request: ZmxInstallRequest(path: remote, projectID: nil, zmxPath: nil),
            release: release,
            binaries: ZmxBinaryProvider(
                cacheDirectory: directory.appendingPathComponent("cache"),
                fetch: { [data = asset.data] _ in data }
            ),
            runner: scripted([
                (0, "system=Linux\nmachine=x86_64\npath=\n"),
                (1, "scp: Connection closed\r\n"),
            ], seen: seen)
        )
        await flow.check()
        await flow.install()
        #expect(flow.phase == .failed)
        #expect(flow.failure?.contains("upload") == true)
        #expect(seen.value.count == 2)
    }
}

@MainActor
struct UTF8ChunkDecoderTests {
    @Test
    func a_shorter_chunk_after_a_longer_one_decodes() {
        // The crash of 1.33.2-tip.27: a long chunk, then a short one.
        var decoder = UTF8ChunkDecoder()
        let long = Array(String(repeating: "x", count: 4096).utf8)
        #expect(decoder.feed(long).count == 4096)
        #expect(decoder.feed(Array("installed=/home/demo/.local/bin/zmx\n".utf8)) == "installed=/home/demo/.local/bin/zmx\n")
        #expect(decoder.feed(Array("ok".utf8)) == "ok")
        #expect(decoder.finish().isEmpty)
    }

    @Test
    func a_character_split_across_chunks_waits_for_its_end() {
        var decoder = UTF8ChunkDecoder()
        let euro = Array("€".utf8) // three bytes
        #expect(decoder.feed(Array("price ".utf8) + euro[0 ..< 1]) == "price ")
        #expect(decoder.feed(euro[1 ..< 2]).isEmpty)
        #expect(decoder.feed(Array(euro[2 ..< 3]) + Array("5".utf8)) == "€5")
        // A four-byte character split after its first byte, then the rest.
        let face = Array("😀".utf8)
        #expect(decoder.feed(face[0 ..< 1]).isEmpty)
        #expect(decoder.feed(face[1 ..< 4]) == "😀")
    }

    @Test
    func an_unfinished_character_at_the_end_decodes_with_replacement() {
        var decoder = UTF8ChunkDecoder()
        #expect(decoder.feed(Array("a".utf8) + [0xE2, 0x82]) == "a")
        #expect(decoder.finish() == "\u{FFFD}")
        #expect(UTF8ChunkDecoder.completePrefixLength([]) == 0)
        #expect(UTF8ChunkDecoder.completePrefixLength([0x80, 0x80]) == 2)
    }
}

/// `TTYCommand` against a real program: the test is the shell asking on
/// its tty, with echo off, and reading what the sheet answers.
@MainActor
struct TTYCommandTests {
    @Test
    func a_program_that_asks_on_its_tty_gets_the_answer() async throws {
        let command = TTYCommand()
        var seen = ""
        try command.start(
            argv: ["/bin/sh", "-c", "printf 'Password: '; stty -echo; read -r p; stty echo; echo; echo \"got:$p\""]
        ) { seen = $0 }
        try await waitUntil { SSHPrompt.detect(in: command.output) == .secret("Password:") }
        #expect(seen.hasSuffix("Password: "))
        // The script prints its prompt before it turns echo off, as a
        // careless program might: the secret waits for echo off.
        #expect(await command.writeSecret("hunter2"))
        let status = await command.waitForExit()
        #expect(status == 0)
        try await waitUntil { command.output.contains("got:hunter2") }
        // Echo was off while the secret went in, so it is not in the output
        // before the program printed it back.
        let before = command.output.range(of: "got:").map { command.output[..<$0.lowerBound] } ?? ""
        #expect(!before.contains("hunter2"))
    }

    @Test
    func a_program_runs_with_a_controlling_terminal() async throws {
        let command = TTYCommand()
        try command.start(argv: ["/bin/sh", "-c", "tty >/dev/null && echo has-tty || echo no-tty; exit 3"]) { _ in }
        let status = await command.waitForExit()
        #expect(status == 3)
        try await waitUntil { command.output.contains("has-tty") }
    }

    @Test
    func a_secret_is_not_written_while_echo_stays_on() async throws {
        let command = TTYCommand()
        try command.start(argv: ["/bin/sh", "-c", "printf 'Password: '; read -r p; echo got:$p"]) { _ in }
        try await waitUntil { command.output.contains("Password:") }
        #expect(command.echoIsOn)
        #expect(await command.writeSecret("hunter2", timeout: .milliseconds(200)) == false)
        #expect(!command.output.contains("hunter2"))
        command.terminate()
        _ = await command.waitForExit()
    }

    @Test
    func terminate_stops_a_program_that_waits() async throws {
        let command = TTYCommand()
        try command.start(argv: ["/bin/sh", "-c", "sleep 30"]) { _ in }
        command.terminate()
        let status = await command.waitForExit()
        #expect(status == 128 + SIGTERM || status == 128 + SIGKILL)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw TimeoutError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct TimeoutError: Error {}
}
