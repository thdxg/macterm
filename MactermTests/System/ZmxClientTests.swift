import Foundation
@testable import Macterm
import Testing

/// Pure-logic coverage for the zmx persistence helpers: the `zmx ls` parser, the
/// socket-path budget probe, session-id formatting, and the launch resolver +
/// shell quoting. The subprocess runner and live daemon interaction need a real
/// zmx binary and are exercised by the manual end-to-end run instead.
struct ZmxSessionListParserTests {
    @Test
    func parsesHealthySessionsWithClientCounts() {
        let stdout = """
        → name=macterm-abc\tclients=1\tcreated=123
          name=macterm-def\tclients=0\tcreated=456
        """
        let entries = ZmxSessionListParser.parse(stdout)
        #expect(entries == [
            .init(name: "macterm-abc", clients: 1),
            .init(name: "macterm-def", clients: 0),
        ])
    }

    @Test
    func absentClientCountIsUnknownNotZero() {
        // An err/status line carries no `clients=`; that must decode to nil
        // (unknown) so the reaper spares it, not 0 (which it would reap).
        let entries = ZmxSessionListParser.parse("  name=macterm-xyz\terr=unreachable")
        #expect(entries == [.init(name: "macterm-xyz", clients: nil)])
    }

    @Test
    func ignoresForeignSessionsWithoutPrefix() {
        // Only `macterm-` sessions are ours; a co-resident tmux/other-app zmx
        // session must be skipped entirely.
        let entries = ZmxSessionListParser.parse("name=other-session\tclients=2")
        #expect(entries.isEmpty)
    }

    @Test
    func emptyListingYieldsNoEntries() {
        #expect(ZmxSessionListParser.parse("").isEmpty)
        #expect(ZmxSessionListParser.parse("\n  \n").isEmpty)
    }

    @Test
    func extractsTheOwnerLabelWhenPresent() {
        // A full `zmx ls` line carries every session label as trailing
        // tab-separated k=v pairs; the owner stamp (#281) rides one of them.
        let stdout = """
        name=macterm-abc\tpid=42\tclients=0\tcreated=123\tcwd=/home/u\tmacterm.owner=cafe01
          name=macterm-def\tclients=0\tcreated=456
        """
        let entries = ZmxSessionListParser.parse(stdout)
        #expect(entries == [
            .init(name: "macterm-abc", clients: 0, owner: "cafe01"),
            .init(name: "macterm-def", clients: 0, owner: nil),
        ])
    }
}

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

    private func entry(_ name: String, clients: Int?, owner: String?) -> ZmxSessionListParser.Entry {
        .init(name: name, clients: clients, owner: owner)
    }

    @Test
    func remote_reaps_only_our_labelled_unclaimed_detached_sessions() {
        let entries = [
            entry("macterm-a", clients: 0, owner: "us"), // ours, orphan → reap
            entry("macterm-b", clients: 0, owner: "them"), // another machine → spare
            entry("macterm-c", clients: 0, owner: nil), // unstamped → spare
            entry("macterm-d", clients: 0, owner: "us"), // claimed → spare
            entry("macterm-e", clients: 1, owner: "us"), // attached → spare
            entry("macterm-f", clients: nil, owner: "us"), // unknown count → spare
            entry("supa-g", clients: 0, owner: "us"), // foreign prefix → spare
        ]
        let orphans = ZmxReaper.orphans(in: entries, known: ["macterm-d"], owner: "us")
        #expect(orphans == ["macterm-a"])
    }

    @Test
    func unstamped_names_claimed_sessions_that_lack_our_label() {
        // A zmx older than 0.7.0 has no `zmx set` and lists no labels, so
        // every claimed session comes back with no owner.
        let entries = [
            entry("macterm-a", clients: 1, owner: "us"), // stamp took → fine
            entry("macterm-b", clients: 1, owner: nil), // old zmx → unstamped
            entry("macterm-c", clients: 0, owner: "them"), // claimed, wrong owner → unstamped
            entry("macterm-d", clients: nil, owner: nil), // err line → no verdict
            entry("macterm-e", clients: 0, owner: nil), // not claimed → not ours to judge
        ]
        let unstamped = ZmxReaper.unstamped(
            in: entries,
            claimed: ["macterm-a", "macterm-b", "macterm-c", "macterm-d", "macterm-gone"],
            owner: "us"
        )
        #expect(unstamped == ["macterm-b", "macterm-c"])
    }

    @Test
    func unstamped_is_empty_when_nothing_is_claimed() {
        let entries = [entry("macterm-a", clients: 0, owner: nil)]
        #expect(ZmxReaper.unstamped(in: entries, claimed: [], owner: "us").isEmpty)
    }

    @Test
    func remote_empty_listing_reaps_nothing() {
        #expect(ZmxReaper.orphans(in: [], known: [], owner: "us").isEmpty)
    }
}

struct ZmxAttachTests {
    @Test
    func wrapperArgvWrapsTheShellWhenExecutablePresent() {
        let argv = ZmxAttach.wrapperArgv(executablePath: "/path/to/zmx", sessionID: "macterm-1")
        #expect(argv == ["/path/to/zmx", "connect", "macterm-1", "--"])
    }

    @Test
    func noExecutableYieldsEmptyArgv() {
        // nil executable (zmx unbundled or over budget) → no wrapper, plain shell.
        #expect(ZmxAttach.wrapperArgv(executablePath: nil, sessionID: "macterm-1").isEmpty)
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
struct ZmxLeadershipTests {
    @Test
    func claimSequenceMatchesTheZmxWireContract() {
        // A wire contract with the zmx fork's `util.ClaimFilter.sequence`, not
        // a local constant: the client scans stdin for these exact bytes, so a
        // drift here means claims are silently typed into the user's shell
        // instead of switching leadership.
        #expect(ZmxLeadership.claimSequence == "\u{1b}_zmx;claim\u{1b}\\")
        // APC, so no keyboard can produce it and terminals discard it unknown.
        #expect(ZmxLeadership.claimSequence.hasPrefix("\u{1b}_"))
        #expect(ZmxLeadership.claimSequence.hasSuffix("\u{1b}\\"))
    }
}

@MainActor
struct ZmxForegroundEventsTests {
    @Test
    func theVariableAndThePrefixMatchTheZmxWireContract() {
        // `foreground.env_var` and `foreground.prefix` in the fork: the
        // client reads the one and the daemon writes the other.
        #expect(ZmxForegroundEvents.environmentVariable == "ZMX_FOREGROUND_EVENTS")
        #expect(ZmxForegroundEvents.reportPrefix == "zmx;foreground;")
    }

    /// The APCs that the v2 attach client writes for the session's
    /// `foreground` message (`server/schema/foreground.json`, written by
    /// `writeForegroundFixtures` in `server/src/attach.zig`). libghostty
    /// gives the app the APC without `ESC _` and `ESC \`.
    @Test
    func theV2AttachClientsAPCsParse() throws {
        struct Fixture: Decodable {
            let name: String
            let apc: String
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // System
            .deletingLastPathComponent() // MactermTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("server/schema/foreground.json")
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
        var parsed: [String: RemoteForeground] = [:]
        for fixture in fixtures {
            var bytes: [UInt8] = []
            var index = fixture.apc.startIndex
            while index < fixture.apc.endIndex {
                let next = fixture.apc.index(index, offsetBy: 2)
                try bytes.append(#require(UInt8(fixture.apc[index ..< next], radix: 16)))
                index = next
            }
            #expect(bytes.starts(with: [0x1B, 0x5F]), "\(fixture.name)")
            #expect(bytes.suffix(2) == [0x1B, 0x5C], "\(fixture.name)")
            let payload = try #require(String(bytes: bytes.dropFirst(2).dropLast(2), encoding: .utf8))
            parsed[fixture.name] = ZmxForegroundEvents.parse(payload)
        }
        #expect(parsed == [
            "program": RemoteForeground(comm: "/usr/bin/hx", isIdle: false, isShell: false, command: "hx a;b.md"),
            "idle shell": RemoteForeground(comm: "-zsh", isIdle: true, isShell: true, command: nil),
            "no /etc/shells": RemoteForeground(comm: "claude", isIdle: false, isShell: nil, command: "claude --resume"),
            "control bytes": RemoteForeground(comm: "ev il", isIdle: false, isShell: false, command: "printf ' \\'"),
        ])
    }

    @Test
    func aReportParsesIntoTheSameShapeAsAProbeLine() {
        let report = ZmxForegroundEvents.parse("zmx;foreground;0;0;/usr/bin/hx;hx --vsplit README.md")
        #expect(report == RemoteForeground(comm: "/usr/bin/hx", isIdle: false, isShell: false, command: "hx --vsplit README.md"))
    }

    @Test
    func theCommandLineIsTheLastFieldAndKeepsItsSemicolons() {
        let report = ZmxForegroundEvents.parse("zmx;foreground;0;0;bash;bash -c echo a; echo b")
        #expect(report?.command == "bash -c echo a; echo b")
    }

    @Test
    func anIdleShellWithNoShellVerdictAndNoCommandLine() {
        let report = ZmxForegroundEvents.parse("zmx;foreground;1;;-zsh;")
        #expect(report == RemoteForeground(comm: "-zsh", isIdle: true, isShell: nil, command: nil))
    }

    @Test
    func anythingElseIsNotAReport() {
        // Another program's APC, a report with a field missing, and one
        // with no name: none may become a sample.
        #expect(ZmxForegroundEvents.parse("Gi=31,s=1,v=1;AAAA") == nil)
        #expect(ZmxForegroundEvents.parse("zmx;claim") == nil)
        #expect(ZmxForegroundEvents.parse("zmx;foreground;0;0;hx") == nil)
        #expect(ZmxForegroundEvents.parse("zmx;foreground;x;0;hx;hx") == nil)
        #expect(ZmxForegroundEvents.parse("zmx;foreground;0;0;;hx") == nil)
        #expect(ZmxForegroundEvents.parse("") == nil)
    }
}
