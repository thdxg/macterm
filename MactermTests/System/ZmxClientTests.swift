import Foundation
@testable import Macterm
import Testing

/// Why new panes start without zmx. Settings reports only a real problem,
/// so the unit-test host (zmx off on purpose) must not read as an over-long
/// socket path.
struct ZmxBypassTests {
    @Test
    func the_unit_test_host_bypasses_on_purpose() {
        #expect(ZmxClient.bypass(environment: ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]) == .unitTestHost)
        // This process is that host.
        #expect(ZmxClient.liveBypass == .unitTestHost)
    }

    @Test
    func a_long_socket_dir_bypasses_with_its_reason() {
        let dir = "/" + String(repeating: "d", count: 80)
        guard case let .socketPathTooLong(reason) = ZmxClient.bypass(environment: ["MACTERM_RUNTIME_DIR": dir]) else {
            Issue.record("expected socketPathTooLong")
            return
        }
        #expect(reason.contains(dir))
    }

    @Test
    func a_short_socket_dir_outside_tests_wraps() {
        #expect(ZmxClient.bypass(environment: ["MACTERM_RUNTIME_DIR": "/tmp/macterm"]) == nil)
    }

    @Test
    func no_runtime_directory_bypasses() {
        #expect(ZmxClient.bypass(environment: [:]) != nil)
    }
}

struct ZmxSocketBudgetTests {
    @Test
    func defaultTmpDirIsUnderBudget() {
        // `/tmp/macterm` + `/macterm-<slug>-<hex>` (33) is well under the
        // 102B budget; probe must pass (nil).
        #expect(ZmxSocketBudget.probe(env: ["TMPDIR": "/tmp/"]) == nil)
    }

    @Test
    func theSocketDirIsTheServersRuntimeDirectory() {
        #expect(ZmxSocketBudget.socketDir(env: ["MACTERM_RUNTIME_DIR": "/custom/dir"]) == "/custom/dir")
        #expect(ZmxSocketBudget.socketDir(env: ["TMPDIR": "/var/tmp/"])?.hasPrefix("/var/tmp/macterm") == true)
        #expect(ZmxSocketBudget.socketDir(env: [:]) == nil)
    }

    @Test
    func theV1DirIsFoundAsV1ZmxFindsIt() {
        // v1's sessions are ended where v1's zmx put them: its resolver
        // trims a trailing slash before it appends.
        #expect(ZmxSocketBudget.v1SocketDir(env: ["ZMX_DIR": "/custom/dir"]) == "/custom/dir")
        #expect(ZmxSocketBudget.v1SocketDir(env: ["XDG_RUNTIME_DIR": "/run/user/501/"]) == "/run/user/501/zmx")
        #expect(ZmxSocketBudget.v1SocketDir(env: ["TMPDIR": "/var/tmp/"]) == "/var/tmp/zmx-\(getuid())")
    }

    @Test
    func overlongDirExceedsBudget() {
        let longDir = "/" + String(repeating: "x", count: 100)
        let reason = ZmxSocketBudget.probe(env: ["MACTERM_RUNTIME_DIR": longDir])
        #expect(reason != nil)
    }
}

struct ZmxSessionNameTests {
    private let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    @Test
    func formats_project_slug_and_short_hex() {
        #expect(ZmxSessionName.make(projectName: "Macterm", paneSessionID: id)
            == "macterm-macterm-aaaaaaaabbbb")
    }

    @Test
    func slug_filters_to_ascii_alphanumerics_and_truncates() {
        #expect(ZmxSessionName.slug("My Cool App!") == "mycoolapp")
        #expect(ZmxSessionName.slug("supersecretproject-alpha") == "supersecretp")
        #expect(ZmxSessionName.slug("supersecretproject-alpha").count == ZmxSessionName.maxSlugLength)
    }

    @Test
    func unslugabble_project_name_falls_back_to_placeholder() {
        // Uniqueness comes from the hex, so a non-ASCII name degrading to a
        // shared placeholder slug is safe.
        #expect(ZmxSessionName.slug("日本語プロジェクト") == "project")
        #expect(ZmxSessionName.slug("--- !!! ---") == "project")
    }

    @Test
    func short_hex_strips_dashes_and_truncates() {
        #expect(ZmxSessionName.shortHex(id) == "aaaaaaaabbbb")
        #expect(ZmxSessionName.shortHex(id).count == ZmxSessionName.shortHexLength)
    }

    @Test
    func max_byte_count_matches_worst_case_name() {
        let worst = ZmxSessionName.make(
            projectName: String(repeating: "x", count: 40),
            paneSessionID: id
        )
        #expect(worst.utf8.count == ZmxSessionName.maxByteCount)
    }

    @Test
    func distinct_panes_in_same_project_get_distinct_names() {
        let a = ZmxSessionName.make(projectName: "proj", paneSessionID: UUID())
        let b = ZmxSessionName.make(projectName: "proj", paneSessionID: UUID())
        #expect(a != b)
    }

    @Test
    func slug_round_trips_through_a_made_name() {
        let name = ZmxSessionName.make(projectName: "My Cool App!", paneSessionID: id)
        #expect(ZmxSessionName.slug(fromName: name) == "mycoolapp")
    }

    @Test
    func slug_recovery_rejects_foreign_or_corrupt_names() {
        #expect(ZmxSessionName.slug(fromName: "supa-abcdef123456") == nil)
        #expect(ZmxSessionName.slug(fromName: "macterm-nohex") == nil)
        #expect(ZmxSessionName.slug(fromName: "macterm--aaaaaaaabbbb") == nil)
        // Slugs may themselves contain hex-looking segments; only a trailing
        // 12-hex-digit component counts as the id.
        #expect(ZmxSessionName.slug(fromName: "macterm-abc-def-aaaaaaaabbbb") == "abc-def")
    }
}

struct ZmxReaperTests {
    @Test
    func local_orphans_are_running_unclaimed_sessions_that_no_client_shows() {
        let sessions = [
            LocalSession(name: "macterm-a", clients: 0), // orphan → end
            LocalSession(name: "macterm-b", clients: 0), // claimed → spare
            LocalSession(name: "macterm-c", clients: 1), // shown → spare
            LocalSession(name: "macterm-d", clients: nil), // unknown count → spare
            LocalSession(name: "macterm-e", isRunning: false, clients: 0), // exited → the app ends it anyway
            LocalSession(name: "user-f", clients: 0), // foreign prefix → spare
        ]
        #expect(ZmxReaper.localOrphans(in: sessions, known: ["macterm-b"]) == ["macterm-a"])
        #expect(ZmxReaper.localOrphans(in: [], known: []).isEmpty)
    }

    @Test @MainActor
    func a_hermetic_run_never_ends_v1_sessions_or_writes_the_flag() {
        // The unit-test host is hermetic, as the benchmark and e2e are.
        #expect(AppState.OnceFlag.preferences.read())
    }
}

/// Touches process-global `ZMX_SESSION`; serialized so a concurrent test can't
/// observe the mutation mid-flight, and the prior value is restored after.
@Suite(.serialized)
struct ZmxEnvironmentTests {
    @Test
    func scrub_removes_inherited_session_marker() {
        // An app launched from inside a Macterm pane inherits the launcher's
        // ZMX_SESSION; once that session dies, every `zmx attach` for a new
        // pane aborts with `session "…" does not exist` instead of creating
        // it. The scrub must remove the marker from this process.
        // Save/restore the process-global env so the mutation doesn't leak to
        // other tests in the shared hosted process.
        let prior = getenv("ZMX_SESSION").map { String(cString: $0) }
        defer {
            if let prior { setenv("ZMX_SESSION", prior, 1) } else { unsetenv("ZMX_SESSION") }
        }
        setenv("ZMX_SESSION", "macterm-test-deadbeefcafe", 1)
        ZmxEnvironment.scrubInheritedSession()
        #expect(getenv("ZMX_SESSION") == nil)
    }
}

@MainActor
struct RemoteForegroundTests {
    @Test
    func a_foreground_message_gives_the_same_shape_as_a_probe_line() {
        let message = MactermProtocol.Foreground(
            idle: false, shell: false, comm: ProtocolBin(Data("/usr/bin/hx".utf8)), args: ProtocolBin(Data("hx a;b.md".utf8))
        )
        #expect(RemoteForeground(message) == RemoteForeground(comm: "/usr/bin/hx", isIdle: false, isShell: false, command: "hx a;b.md"))
    }

    @Test
    func an_idle_shell_with_no_shell_verdict_and_no_command_line() {
        let message = MactermProtocol.Foreground(idle: true, shell: nil, comm: ProtocolBin(Data("-zsh".utf8)), args: ProtocolBin(Data()))
        #expect(RemoteForeground(message) == RemoteForeground(comm: "-zsh", isIdle: true, isShell: nil, command: nil))
    }

    @Test
    func a_message_with_no_name_is_not_a_sample() {
        let message = MactermProtocol.Foreground(idle: false, shell: false, comm: ProtocolBin(Data()), args: ProtocolBin(Data("hx".utf8)))
        #expect(RemoteForeground(message) == nil)
    }
}
