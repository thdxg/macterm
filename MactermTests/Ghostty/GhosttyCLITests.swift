import Foundation
@testable import Macterm
import Testing

struct GhosttyCLITests {
    private func cli(
        candidates: [String],
        executable: Set<String>,
        sshCapable: Set<String> = []
    ) -> GhosttyCLI {
        GhosttyCLI(
            binDirCandidates: candidates,
            isExecutable: { executable.contains($0) },
            supportsSSHAction: { sshCapable.contains($0) }
        )
    }

    @Test
    func resolves_first_candidate_with_executable() {
        let c = cli(
            candidates: ["/Applications/Ghostty.app/Contents/MacOS", "/home/Ghostty.app/Contents/MacOS"],
            executable: ["/home/Ghostty.app/Contents/MacOS/ghostty"]
        )
        #expect(c.resolveBinDir() == "/home/Ghostty.app/Contents/MacOS")
        #expect(c.isInstalled)
    }

    @Test
    func prefers_higher_priority_candidate() {
        let c = cli(
            candidates: ["/a", "/b"],
            executable: ["/a/ghostty", "/b/ghostty"]
        )
        #expect(c.resolveBinDir() == "/a")
    }

    @Test
    func not_installed_when_no_executable() {
        let c = cli(candidates: ["/a", "/b"], executable: [])
        #expect(c.resolveBinDir() == nil)
        #expect(!c.isInstalled)
    }

    @Test
    func ssh_wrapper_bin_dir_requires_ssh_support() {
        // Binary present and supports `+ssh` → usable for the wrappers.
        let capable = cli(
            candidates: ["/a"],
            executable: ["/a/ghostty"],
            sshCapable: ["/a/ghostty"]
        )
        #expect(capable.resolveSSHWrapperBinDir() == "/a")
    }

    @Test
    func ssh_wrapper_bin_dir_nil_when_cli_too_old() {
        // Binary present but no `+ssh` action (e.g. Ghostty 1.3.1) → not usable;
        // the wrappers must be disabled so ssh falls through to plain ssh.
        let old = cli(
            candidates: ["/a"],
            executable: ["/a/ghostty"],
            sshCapable: []
        )
        #expect(old.resolveBinDir() == "/a") // still "installed"
        #expect(old.isInstalled)
        #expect(old.resolveSSHWrapperBinDir() == nil) // but not ssh-capable
    }

    @Test
    func ssh_wrapper_bin_dir_nil_when_not_installed() {
        let none = cli(candidates: ["/a"], executable: [], sshCapable: ["/a/ghostty"])
        #expect(none.resolveSSHWrapperBinDir() == nil)
    }

    @Test
    func ssh_support_probed_against_resolved_bin_dir() {
        // The probe must run against the *resolved* binary, not a lower-priority
        // candidate that happens to be ssh-capable.
        let c = cli(
            candidates: ["/a", "/b"],
            executable: ["/a/ghostty", "/b/ghostty"],
            sshCapable: ["/b/ghostty"] // only the lower-priority one is capable
        )
        #expect(c.resolveBinDir() == "/a")
        #expect(c.resolveSSHWrapperBinDir() == nil)
    }
}
