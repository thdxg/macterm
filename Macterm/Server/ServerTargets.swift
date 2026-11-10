import Foundation

/// The host targets that the app carries a server build for
/// (`Contents/Resources/server/macterm-<key>-<target>.gz`), as
/// `scripts/build-server.sh` names them.
enum ZmxHostTarget: String, CaseIterable, Equatable {
    case linuxX86_64 = "x86_64-linux"
    case linuxAarch64 = "aarch64-linux"
    case macOS = "universal-macos"

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
    /// `1.0.1`, as upstream prints it.
    var upstream: String
    /// `build-2026-11-06-abcdef1` from `1.0.1+thdxg.build-2026-11-06-abcdef1`,
    /// nil for an upstream binary or a fork build older than the marker.
    var forkTag: String?

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
