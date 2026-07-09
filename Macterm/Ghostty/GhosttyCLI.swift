import Foundation
import os

/// Detection for the external ghostty CLI binary (shipped inside Ghostty.app).
///
/// libghostty is embedded in Macterm, but a handful of shell-integration
/// wrappers exec the standalone `ghostty` CLI at runtime. Macterm ships no such
/// binary, so those wrappers only work when the user also has Ghostty.app
/// installed. When it's missing, `MactermConfig` disables the dependent
/// shell-integration features and Settings surfaces a banner.
///
/// Detection isn't just "is a binary present" — it's "is a *compatible* binary
/// present". The bundled shell-integration scripts come from a newer ghostty
/// (`thdxg/ghostty`) whose `ssh` wrapper invokes `ghostty +ssh -- <args>`. An
/// older installed Ghostty.app (e.g. 1.3.1) has no `+ssh` action, so the
/// wrapper dies with "Ghostty failed to initialize!" — strictly worse than not
/// wrapping `ssh` at all. So we probe for the `+ssh` action before pointing the
/// wrappers at the binary; a present-but-too-old CLI is treated as unusable for
/// the ssh wrappers and they're disabled (ssh falls through to plain `ssh`).
///
/// Selection logic only — the candidate paths, a filesystem probe, and the
/// `+ssh`-support probe are injected so the detection is unit-testable without
/// touching disk or spawning the binary.
struct GhosttyCLI {
    /// Directories that may contain the `ghostty` CLI, highest priority first.
    let binDirCandidates: [String]
    /// Filesystem executable probe. Injected so tests don't touch disk.
    let isExecutable: (String) -> Bool
    /// Whether the `ghostty` binary at the given path supports the `+ssh`
    /// action the bundled shell-integration wrappers depend on. Injected so
    /// tests don't have to spawn a process.
    let supportsSSHAction: (String) -> Bool

    /// The directory holding the `ghostty` binary, or nil when none is found.
    /// This is a plain presence check — the binary may be too old to drive the
    /// ssh wrappers; use `resolveSSHWrapperBinDir()` for that.
    func resolveBinDir() -> String? {
        binDirCandidates.first { isExecutable($0 + "/ghostty") }
    }

    /// The directory holding a `ghostty` binary that's new enough to support the
    /// ssh shell-integration wrappers (`ghostty +ssh`), or nil when none is.
    /// `MactermConfig` feeds this into `GHOSTTY_BIN_DIR` only when non-nil;
    /// otherwise it disables the ssh wrappers so `ssh` falls through to plain
    /// `ssh` instead of failing on an unknown `+ssh` action.
    func resolveSSHWrapperBinDir() -> String? {
        guard let binDir = resolveBinDir() else { return nil }
        return supportsSSHAction(binDir + "/ghostty") ? binDir : nil
    }

    /// Whether any `ghostty` CLI is installed (regardless of version).
    var isInstalled: Bool { resolveBinDir() != nil }
}

/// Process-lifetime cache of the standard CLI probe. `resolveSSHWrapperBinDir`
/// spawns a blocking `ghostty +help` subprocess, and both `MactermConfig`
/// (before every config reload) and `SettingsView.body` (every render) ask for
/// it — but the installed CLI can't change in any way Macterm reacts to within
/// a launch, so the answer is computed once and reused. This keeps the blocking
/// spawn off the config-reload hot path (#3.2) and out of SwiftUI `body` (#3.1).
enum GhosttyCLIProbe {
    private struct Result {
        let binDir: String?
        let sshWrapperBinDir: String?
        var isInstalled: Bool { binDir != nil }
    }

    private static let cache = OSAllocatedUnfairLock<Result?>(initialState: nil)

    private static func resolve() -> Result {
        cache.withLock { current in
            if let current { return current }
            let cli = GhosttyCLI.standard
            let result = Result(
                binDir: cli.resolveBinDir(),
                sshWrapperBinDir: cli.resolveSSHWrapperBinDir()
            )
            current = result
            return result
        }
    }

    static var binDir: String? { resolve().binDir }
    static var sshWrapperBinDir: String? { resolve().sshWrapperBinDir }
    static var isInstalled: Bool { resolve().isInstalled }
}

extension GhosttyCLI {
    /// The detector Macterm uses at runtime: probes the standard Ghostty.app
    /// install locations on disk.
    static var standard: GhosttyCLI {
        GhosttyCLI(
            binDirCandidates: [
                "/Applications/Ghostty.app/Contents/MacOS",
                NSHomeDirectory() + "/Applications/Ghostty.app/Contents/MacOS",
            ],
            isExecutable: FileManager.default.isExecutableFile(atPath:),
            supportsSSHAction: GhosttyCLI.probeSSHAction(at:)
        )
    }

    /// Runs `ghostty +help` and checks whether `+ssh` is listed among the
    /// available actions. `+help` exits 0 and prints one action per line; older
    /// builds simply don't list `+ssh`. We avoid invoking `+ssh` directly so we
    /// never risk a real connection attempt during a feature probe.
    private static func probeSSHAction(at path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["+help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8)
        else { return false }
        return output
            .split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == "+ssh" }
    }
}
