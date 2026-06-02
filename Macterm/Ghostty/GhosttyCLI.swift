import Foundation

/// Detection for the external ghostty CLI binary (shipped inside Ghostty.app).
///
/// libghostty is embedded in Macterm, but a handful of shell-integration
/// wrappers exec the standalone `ghostty` CLI at runtime. Macterm ships no such
/// binary, so those wrappers only work when the user also has Ghostty.app
/// installed. When it's missing, `MactermConfig` disables the dependent
/// shell-integration features and Settings surfaces a banner.
///
/// Selection logic only — the candidate paths and a filesystem probe are
/// injected so the detection is unit-testable without touching disk.
struct GhosttyCLI {
    /// Directories that may contain the `ghostty` CLI, highest priority first.
    let binDirCandidates: [String]
    /// Filesystem executable probe. Injected so tests don't touch disk.
    let isExecutable: (String) -> Bool

    /// The directory holding the `ghostty` binary, or nil when none is found.
    /// `MactermConfig` feeds this into `GHOSTTY_BIN_DIR` for spawned shells.
    func resolveBinDir() -> String? {
        binDirCandidates.first { isExecutable($0 + "/ghostty") }
    }

    var isInstalled: Bool { resolveBinDir() != nil }
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
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        )
    }
}
