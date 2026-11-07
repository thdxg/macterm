import Foundation

/// The pure half of installing Macterm's zmx fork on the host of a remote
/// project (#699): which release asset fits a host, what `zmx version` on
/// the host says, and what the install sheet offers. `RemoteZmxInstaller`
/// does the connections.
///
/// A remote pane is a zmx session on the host, and the docs told users to
/// install upstream zmx. Upstream zmx has none of the fork's patches: the
/// leadership claim, the scrollback replay fixes, the foreground reports
/// (#695). The fork publishes a static Linux binary for x86_64 and aarch64
/// and a universal macOS binary, each with a `.sha256` beside it, and its
/// `zmx version` says which build it is (`<upstream>+thdxg.<release tag>`).
enum ZmxHostTarget: String, CaseIterable, Equatable {
    case linuxX86_64 = "x86_64-linux"
    case linuxAarch64 = "aarch64-linux"
    case macOS = "universal-macos"

    /// The release asset of `thdxg/zmx` for this target: a tarball that
    /// holds one `zmx`.
    var assetName: String { "zmx-\(rawValue).tar.gz" }

    var displayName: String {
        switch self {
        case .linuxX86_64: "Linux x86_64"
        case .linuxAarch64: "Linux aarch64"
        case .macOS: "macOS"
        }
    }

    /// The target from the host's `uname -s` and `uname -m`. Linux names the
    /// CPU as `x86_64` or `amd64`, and `aarch64` or `arm64`. A macOS host
    /// takes the universal build, whatever its CPU. Anything else (a BSD,
    /// a 32-bit or RISC-V Linux) has no build.
    static func detect(system: String, machine: String) -> ZmxHostTarget? {
        let system = system.trimmingCharacters(in: .whitespacesAndNewlines)
        let machine = machine.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch system {
        case "Darwin":
            return .macOS
        case "Linux":
            switch machine {
            case "x86_64",
                 "amd64": return .linuxX86_64
            case "aarch64",
                 "arm64": return .linuxAarch64
            default: return nil
            }
        default:
            return nil
        }
    }
}

/// What `zmx version` on a host says: the upstream version, and the fork's
/// release tag when the binary is one of ours.
struct ZmxVersion: Equatable {
    /// `0.8.1`, as upstream prints it.
    var upstream: String
    /// `build-2026-11-06-abcdef1` from `0.8.1+thdxg.build-2026-11-06-abcdef1`,
    /// nil for an upstream binary or a fork build older than the marker.
    var forkTag: String?

    var isFork: Bool { forkTag != nil }

    /// The wire protocol this zmx speaks: 1.0 and later is v1, anything
    /// before is legacy (`ZmxProtocol`). The two never talk.
    var wireProtocol: ZmxProtocol {
        let major = upstream.split(separator: ".").first.flatMap { Int($0) } ?? 0
        return major >= 1 ? .v1 : .legacy
    }

    static let forkMarker = "+thdxg."

    /// The version from the first line of `zmx version`, which is
    /// `zmx<TAB><TAB><version>`, or from a bare version string. nil for
    /// anything that does not look like a version.
    static func parse(_ output: String) -> ZmxVersion? {
        guard let firstLine = output.split(whereSeparator: \.isNewline).first else { return nil }
        var text = firstLine.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("zmx") {
            text = text.dropFirst(3).trimmingCharacters(in: .whitespaces)
        }
        guard let first = text.first, first.isNumber else { return nil }
        guard !text.contains(where: \.isWhitespace) else { return nil }
        if let marker = text.range(of: forkMarker) {
            let tag = String(text[marker.upperBound...])
            guard !tag.isEmpty else { return nil }
            return ZmxVersion(upstream: String(text[..<marker.lowerBound]), forkTag: tag)
        }
        return ZmxVersion(upstream: text, forkTag: nil)
    }
}

/// What one check of a host found (`RemoteSpawn.zmxHostCheckScript`).
struct ZmxHostState: Equatable {
    var system: String
    var machine: String
    /// The zmx the host runs for the project: `zmxPath` when the project
    /// sets one, else the first `zmx` in the login's PATH. nil when none.
    var zmxPath: String?
    /// What that zmx says, nil when there is none or it did not answer.
    var version: ZmxVersion?

    var target: ZmxHostTarget? { ZmxHostTarget.detect(system: system, machine: machine) }

    /// Whether installing a build of protocol `installing` must end the
    /// host's Macterm sessions first: the host's zmx is older than 1.0 and
    /// the build is 1.0 or later. The new zmx cannot reach the old
    /// sessions, and a pane that reattaches to one hangs. An unknown build
    /// ends nothing: no session ends without the evidence.
    func installEndsSessions(installing: ZmxProtocol?) -> Bool {
        zmxPath != nil && version?.wireProtocol == .legacy && installing == .v1
    }

    /// The script prints `key=value` lines. A missing `system` or `machine`
    /// means the script did not run (an ssh that printed something else),
    /// and the check failed.
    static func parse(_ output: String) -> ZmxHostState? {
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq])
            guard ["system", "machine", "path", "version"].contains(key) else { continue }
            fields[key] = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let system = fields["system"], !system.isEmpty,
              let machine = fields["machine"], !machine.isEmpty
        else { return nil }
        let path = fields["path"].flatMap { $0.isEmpty ? nil : $0 }
        return ZmxHostState(
            system: system,
            machine: machine,
            zmxPath: path,
            version: path == nil ? nil : fields["version"].flatMap(ZmxVersion.parse)
        )
    }
}

/// What the install sheet offers for a host, decided from the check and the
/// release this Macterm build carries.
enum ZmxInstallVerdict: Equatable {
    /// No build for this host's OS and CPU.
    case unsupported(system: String, machine: String)
    /// The host has no zmx, or the project's `zmxPath` names nothing.
    case missing
    /// The host runs upstream zmx (or a fork build older than the marker).
    case upstream(ZmxVersion)
    /// The host runs a fork build that is not the one this Macterm pins.
    case otherBuild(ZmxVersion)
    /// The host runs the pinned build.
    case current(ZmxVersion)

    static func decide(state: ZmxHostState, pinnedTag: String) -> ZmxInstallVerdict {
        guard state.target != nil else { return .unsupported(system: state.system, machine: state.machine) }
        guard state.zmxPath != nil, let version = state.version else { return .missing }
        guard let tag = version.forkTag else { return .upstream(version) }
        return tag == pinnedTag ? .current(version) : .otherBuild(version)
    }

    /// Whether the sheet offers to install, and as what.
    var offer: Offer? {
        switch self {
        case .unsupported,
             .current: nil
        case .missing: .install
        case .upstream,
             .otherBuild: .update
        }
    }

    enum Offer: Equatable {
        case install
        case update
    }
}

/// The fork release this Macterm build was made with: its tag and the
/// SHA-256 of each asset. `scripts/setup.sh` writes it into the bundle as
/// `zmx-release.json` from the release's `.sha256` files, so an installer
/// can check a download before it goes over ssh. A release from before the
/// checksums lists no assets, and the sheet then says the build has no
/// binary for the host.
struct ZmxRelease: Codable, Equatable {
    var tag: String
    /// What the build's `zmx version` says, `1.0.1+thdxg.<tag>`. nil in a
    /// file from before the field.
    var version: String?

    /// The wire protocol of the build, nil when the file does not say.
    var wireProtocol: ZmxProtocol? {
        version.flatMap(ZmxVersion.parse)?.wireProtocol
    }

    /// Asset name → lowercase SHA-256 hex.
    var assets: [String: String]

    static let resourceName = "zmx-release"

    /// The release in the app bundle, nil when setup did not write it.
    static var bundled: ZmxRelease? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json") else { return nil }
        return load(from: url)
    }

    static func load(from url: URL) -> ZmxRelease? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ZmxRelease.self, from: data)
    }

    /// The checksum of the asset for `target`, nil when the release has none.
    func sha256(for target: ZmxHostTarget) -> String? {
        assets[target.assetName].map { $0.lowercased() }
    }

    /// Where GitHub serves the asset.
    func downloadURL(for target: ZmxHostTarget) -> URL? {
        URL(string: "https://github.com/thdxg/zmx/releases/download/\(tag)/\(target.assetName)")
    }

    /// The release file from the `<hash>  <name>` lines of the `.sha256`
    /// files (`shasum -a 256` and `sha256sum` both print that shape).
    static func make(tag: String, checksumLines: [String]) -> ZmxRelease {
        var assets: [String: String] = [:]
        for line in checksumLines {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, parts[0].count == 64 else { continue }
            var name = String(parts[1])
            if name.hasPrefix("*") { name.removeFirst() }
            assets[name] = String(parts[0]).lowercased()
        }
        return ZmxRelease(tag: tag, version: nil, assets: assets)
    }
}

/// A prompt an ssh connection printed and waits on, found in the output of
/// the pty that runs it (`TTYCommand`): a password or a key passphrase,
/// which the sheet asks for in a secure field, or a host-key question, which
/// it asks as yes or no. Pure.
enum SSHPrompt: Equatable {
    case secret(String)
    case yesNo(String)

    /// The prompt at the end of `output`, if the last line is one. ssh
    /// prints a prompt without a newline and waits, so only the tail
    /// counts; a line that ended is history.
    static func detect(in output: String) -> SSHPrompt? {
        // `Character`, not bytes: "\r\n" is one character, which neither
        // `hasSuffix("\n")` nor a comparison with "\n" sees.
        guard output.last?.isNewline != true else { return nil }
        let tail = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).last
        guard let line = tail.map({ $0.trimmingCharacters(in: .whitespaces) }), !line.isEmpty else { return nil }
        let lower = line.lowercased()
        if lower.hasSuffix("(yes/no)?") || lower.hasSuffix("(yes/no/[fingerprint])?") || lower.hasSuffix("(yes/no/[fingerprint])? ") {
            return .yesNo(line)
        }
        guard line.hasSuffix(":") else { return nil }
        if lower.contains("password") || lower.contains("passphrase") || lower.contains("passcode")
            || lower.contains("verification code") || lower.contains("one-time")
        {
            return .secret(line)
        }
        return nil
    }
}
