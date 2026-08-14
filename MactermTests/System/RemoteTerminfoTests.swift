import Foundation
@testable import Macterm
import Testing

struct RemoteTerminfoTests {
    private let remote = ProjectPath.remote(user: nil, host: "devbox", directory: "~/dev/api")

    @Test
    func install_argv_is_noninteractive_and_compiles_from_stdin() {
        let argv = RemoteTerminfo.installArgv(remote: remote)
        // Same profile as every other background op: BatchMode so an auth
        // prompt can never hang the task, ConnectTimeout so a dead host can't
        // wedge it. This runs off the pane's critical path — it must fail fast
        // and silently rather than ever delaying a spawn.
        #expect(argv?.prefix(4) == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"])
        #expect(argv?.dropFirst(4).first == "devbox")
        // `tic -x -` compiles the piped source into the user's own ~/.terminfo,
        // needing no privileges. `-x` must match `infocmp -x` or the extended
        // caps (Tc/RGB — the entire point) are dropped in transit.
        #expect(argv?.last?.contains("exec tic -x -") == true)
        #expect(RemoteTerminfo.sourceArgv() == ["-x", RemoteTerminfo.entryName])
        // sh -c wrapped, single-quote-free, PATH preamble applied — the wire
        // format every remote command obeys so any login shell delivers it.
        #expect(argv?.last?.hasPrefix("\(RemoteSpawn.remoteShell) ") == true)
        #expect(argv?.last?.contains(RemoteSpawn.remoteEnvPreamble) == true)
    }

    @Test
    func install_argv_includes_user_in_destination_and_is_nil_for_local() {
        let argv = RemoteTerminfo.installArgv(
            remote: .remote(user: "deploy", host: "10.0.0.5", directory: "/srv/app")
        )
        #expect(argv?.dropFirst(4).first == "deploy@10.0.0.5")
        #expect(RemoteTerminfo.installArgv(remote: .local("/a/b")) == nil)
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

    /// Records what the installer asked for, standing in for infocmp + ssh.
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
            install: { remote, dir in
                recorder.destinations.append(RemoteTerminfo.destinationKey(remote: remote) ?? "?")
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
        let one = ProjectPath.remote(user: "deploy", host: "node-1", directory: "~/one")
        let two = ProjectPath.remote(user: "deploy", host: "node-1", directory: "~/two")
        // Two panes on one host — including a second project on the same host —
        // must not each rewrite the host's terminfo.
        installer.ensureInstalled(remote: one)
        installer.ensureInstalled(remote: one)
        installer.ensureInstalled(remote: two)
        // A different user on the same host IS a different destination.
        installer.ensureInstalled(remote: .remote(user: "root", host: "node-1", directory: "~/one"))
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
        installer.ensureInstalled(remote: remote)
        await waitForInstalls(recorder, count: 0)
        // ghostty ships ssh-terminfo off; writing files onto a user's server is
        // not something to start doing unasked.
        #expect(recorder.destinations.isEmpty)
    }

    @MainActor
    @Test
    func installer_skips_local_panes_and_an_unresolved_bundle() async {
        let recorder = Recorder()
        makeInstaller(recorder: recorder).ensureInstalled(remote: .local("/Users/me/dev"))
        // No bundled terminfo dir (a dev checkout before setup.sh) must not
        // ship the *system* entry as if it were ours.
        makeInstaller(terminfoDirectory: nil, recorder: recorder).ensureInstalled(remote: remote)
        await waitForInstalls(recorder, count: 0)
        #expect(recorder.destinations.isEmpty)
    }

    @MainActor
    @Test
    func a_failed_install_is_not_retried_for_the_rest_of_the_run() async {
        let recorder = Recorder()
        recorder.result = false
        let installer = makeInstaller(recorder: recorder)
        installer.ensureInstalled(remote: remote)
        await waitForInstalls(recorder, count: 1)
        installer.ensureInstalled(remote: remote)
        await waitForInstalls(recorder, count: 0)
        // A host that has already said no (no tic, read-only terminfo dir,
        // interactive-only auth) must not cost an ssh connection per pane
        // spawn. The next launch tries again.
        #expect(recorder.destinations == ["devbox"])
    }

    @Test
    func destination_key_is_per_host_and_user_not_per_project() {
        // Terminfo is installed per host+user; two projects on one host must
        // share a single install, and the same host as a different user must
        // not be considered already done.
        let a = ProjectPath.remote(user: "deploy", host: "node-1", directory: "~/one")
        let b = ProjectPath.remote(user: "deploy", host: "node-1", directory: "~/two")
        let c = ProjectPath.remote(user: "root", host: "node-1", directory: "~/one")
        #expect(RemoteTerminfo.destinationKey(remote: a) == RemoteTerminfo.destinationKey(remote: b))
        #expect(RemoteTerminfo.destinationKey(remote: a) != RemoteTerminfo.destinationKey(remote: c))
        #expect(RemoteTerminfo.destinationKey(remote: .local("/a")) == nil)
    }
}
