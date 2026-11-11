import Foundation
@testable import Macterm
import Testing

struct RemoteTerminfoTests {
    @Test
    func install_argv_compiles_the_source_on_the_host() {
        let argv = RemoteTerminfo.installArgv(source: "xterm-ghostty|ghostty,\n")
        // The host's server runs it with no shell in front: argv, not text
        // that a login shell parses. The source is `$1`, because
        // `command.run` gives the command no stdin.
        #expect(argv.prefix(2) == ["/bin/sh", "-c"])
        #expect(argv.dropFirst(3) == ["sh", "xterm-ghostty|ghostty,\n"])
        // `tic -x -o ~/.terminfo -` compiles into the user's own
        // ~/.terminfo, as ghostty's +ssh does: without `-o`, a tic that runs
        // as root writes the system database. `-x` must match `infocmp -x`
        // or the extended caps (Tc/RGB — the entire point) are dropped in
        // transit. The infocmp after it checks the entry resolves, and
        // stderr goes into the output for the log.
        #expect(argv[2] == RemoteSpawn.remoteEnvPreamble
            + "printf \"%s\" \"$1\" | { tic -x -o ~/.terminfo - && infocmp -x xterm-ghostty >/dev/null; } 2>&1")
        #expect(RemoteTerminfo.sourceArgv() == ["-x", RemoteTerminfo.entryName])
    }

    @Test
    func the_installed_entry_is_the_one_the_pane_script_looks_for() {
        // If these two ever drift, the installer would ship an entry the
        // preamble never checks for and every host would silently stay on
        // xterm-256color.
        #expect(RemoteSpawn.remoteTermPreamble.contains("infocmp \(RemoteTerminfo.entryName) "))
        #expect(RemoteSpawn.remoteTermPreamble.contains("TERM=\(RemoteTerminfo.entryName);"))
    }

    @Test
    func source_environment_pins_terminfo_to_our_own_bundle() {
        // TERM=xterm-ghostty on the remote is a promise about what OUR pinned
        // libghostty supports, so the source must come from our bundled DB —
        // never an installed Ghostty.app's, and never the system search path.
        // This process deliberately leaves TERMINFO unset (libghostty
        // overwrites it at shell spawn), so an inherited value would resolve
        // against the system DB instead.
        let env = RemoteTerminfo.sourceEnvironment(terminfoDirectory: "/Bundle/Resources/terminfo")
        #expect(env["TERMINFO"] == "/Bundle/Resources/terminfo")
        // The rest of the environment survives — this is a plain subprocess.
        #expect(env["PATH"] != nil)
    }

    // MARK: - Installer

    /// Records what the installer asked for, standing in for infocmp and the
    /// host's server.
    @MainActor
    private final class Recorder {
        var destinations: [String] = []
        var terminfoDirectories: [String] = []
        var result = true
    }

    @MainActor
    private func makeInstaller(
        enabled: Bool = true,
        terminfoDirectory: String? = "/Bundle/Resources/terminfo",
        recorder: Recorder
    ) -> RemoteTerminfoInstaller {
        RemoteTerminfoInstaller(
            isEnabled: { enabled },
            terminfoDirectory: { terminfoDirectory },
            install: { destination, dir in
                recorder.destinations.append(destination)
                recorder.terminfoDirectories.append(dir)
                return recorder.result
            }
        )
    }

    /// The install runs in a spawned Task, so wait on the observable outcome —
    /// a deadline poll that SLEEPS, never a fixed count of `Task.yield()`
    /// (which starves timers on the main actor and flakes under CI load).
    /// `expected` is the count to wait *for*; a test asserting nothing happened
    /// passes 0 and simply gets the full quiet wait.
    @MainActor
    private func waitForInstalls(_ recorder: Recorder, count expected: Int) async {
        // A "nothing happened" assertion can't wait for a signal, so it takes a
        // short fixed quiet period; a positive one polls up to a generous
        // deadline and returns the moment it's satisfied.
        for _ in 0 ..< (expected > 0 ? 200 : 30) {
            if expected > 0, recorder.destinations.count >= expected { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    @Test
    func installer_attempts_once_per_destination_per_run() async {
        let recorder = Recorder()
        let installer = makeInstaller(recorder: recorder)
        // Two connects to one host must not each rewrite the host's terminfo.
        installer.ensureInstalled(destination: "deploy@node-1")
        installer.ensureInstalled(destination: "deploy@node-1")
        // A different user on the same host IS a different destination.
        installer.ensureInstalled(destination: "root@node-1")
        await waitForInstalls(recorder, count: 2)
        #expect(recorder.destinations == ["deploy@node-1", "root@node-1"])
        // The source always comes from our own bundled DB.
        #expect(recorder.terminfoDirectories.allSatisfy { $0 == "/Bundle/Resources/terminfo" })
    }

    @MainActor
    @Test
    func installer_does_nothing_unless_the_user_enabled_ssh_terminfo() async {
        let recorder = Recorder()
        let installer = makeInstaller(enabled: false, recorder: recorder)
        installer.ensureInstalled(destination: "devbox")
        await waitForInstalls(recorder, count: 0)
        // ghostty ships ssh-terminfo off; writing files onto a user's server is
        // not something to start doing unasked.
        #expect(recorder.destinations.isEmpty)
    }

    @MainActor
    @Test
    func installer_skips_an_unresolved_bundle() async {
        let recorder = Recorder()
        // No bundled terminfo dir (a dev checkout before setup.sh) must not
        // ship the *system* entry as if it were ours.
        makeInstaller(terminfoDirectory: nil, recorder: recorder).ensureInstalled(destination: "devbox")
        await waitForInstalls(recorder, count: 0)
        #expect(recorder.destinations.isEmpty)
    }

    @MainActor
    @Test
    func a_failed_install_is_not_retried_for_the_rest_of_the_run() async {
        let recorder = Recorder()
        recorder.result = false
        let installer = makeInstaller(recorder: recorder)
        installer.ensureInstalled(destination: "devbox")
        await waitForInstalls(recorder, count: 1)
        installer.ensureInstalled(destination: "devbox")
        await waitForInstalls(recorder, count: 0)
        // A host that has already said no (no tic, read-only terminfo dir)
        // is not asked again at each connect. The next launch tries again.
        #expect(recorder.destinations == ["devbox"])
    }
}
