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
}

struct ZmxSocketBudgetTests {
    @Test
    func defaultTmpDirIsUnderBudget() {
        // `/tmp/zmx-<uid>` (~13 chars) + `/macterm-<UUID>` (45) is well under
        // the 102B budget; probe must pass (nil).
        #expect(ZmxSocketBudget.probe(env: [:]) == nil)
    }

    @Test
    func explicitZmxDirWins() {
        #expect(ZmxSocketBudget.socketDir(env: ["ZMX_DIR": "/custom/dir"]) == "/custom/dir")
    }

    @Test
    func trailingSlashIsTrimmedForDerivedDirs() {
        // The derived (non-ZMX_DIR) paths must match zmx's own resolver, which
        // trims a trailing slash before appending — otherwise kill and the
        // wrapped shell land on different socket dirs.
        #expect(ZmxSocketBudget.socketDir(env: ["XDG_RUNTIME_DIR": "/run/user/501/"]) == "/run/user/501/zmx")
        #expect(ZmxSocketBudget.socketDir(env: ["TMPDIR": "/var/tmp/"]) == "/var/tmp/zmx-\(getuid())")
    }

    @Test
    func overlongDirExceedsBudget() {
        let longDir = "/" + String(repeating: "x", count: 100)
        let reason = ZmxSocketBudget.probe(env: ["ZMX_DIR": longDir])
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
    private func entry(_ name: String, clients: Int?) -> ZmxSessionListParser.Entry {
        .init(name: name, clients: clients)
    }

    @Test
    func reaps_unclaimed_detached_macterm_sessions() {
        let entries = [
            entry("macterm-a", clients: 0), // orphan → reap
            entry("macterm-b", clients: 0), // claimed → spare
        ]
        let orphans = ZmxReaper.orphans(in: entries, known: ["macterm-b"])
        #expect(orphans == ["macterm-a"])
    }

    @Test
    func spares_attached_sessions_even_if_unclaimed() {
        // clients > 0 means a live client (another instance / manual attach) —
        // never reap regardless of the known set.
        let orphans = ZmxReaper.orphans(in: [entry("macterm-x", clients: 1)], known: [])
        #expect(orphans.isEmpty)
    }

    @Test
    func spares_unknown_client_count() {
        // nil clients (err/status line) = unknown → spare.
        let orphans = ZmxReaper.orphans(in: [entry("macterm-x", clients: nil)], known: [])
        #expect(orphans.isEmpty)
    }

    @Test
    func never_touches_foreign_prefix_sessions() {
        // A co-resident Supacode session must never be reaped by Macterm.
        let entries = [
            entry("supa-abc", clients: 0),
            entry("macterm-y", clients: 0),
        ]
        let orphans = ZmxReaper.orphans(in: entries, known: [])
        #expect(orphans == ["macterm-y"])
    }

    @Test
    func empty_listing_reaps_nothing() {
        #expect(ZmxReaper.orphans(in: [], known: ["macterm-a"]).isEmpty)
    }
}

struct ZmxAttachTests {
    @Test
    func wrapperArgvWrapsTheShellWhenExecutablePresent() {
        let argv = ZmxAttach.wrapperArgv(executablePath: "/path/to/zmx", sessionID: "macterm-1")
        #expect(argv == ["/path/to/zmx", "attach", "macterm-1"])
    }

    @Test
    func noExecutableYieldsEmptyArgv() {
        // nil executable (zmx unbundled or over budget) → no wrapper, plain shell.
        #expect(ZmxAttach.wrapperArgv(executablePath: nil, sessionID: "macterm-1").isEmpty)
    }
}

struct ZmxEnvironmentTests {
    @Test
    func scrub_removes_inherited_session_marker() {
        // An app launched from inside a Macterm pane inherits the launcher's
        // ZMX_SESSION; once that session dies, every `zmx attach` for a new
        // pane aborts with `session "…" does not exist` instead of creating
        // it. The scrub must remove the marker from this process.
        setenv("ZMX_SESSION", "macterm-test-deadbeefcafe", 1)
        ZmxEnvironment.scrubInheritedSession()
        #expect(getenv("ZMX_SESSION") == nil)
    }
}

/// Drives the async `reapOrphans` over an injected `ZmxClient` (no real
/// subprocess), so the known-set mapping, the nil-probe short-circuit, and the
/// kill fan-out are covered end to end — not just the pure `ZmxReaper.orphans`.
struct ZmxReapOrphansDriverTests {
    /// A client whose `ls` returns `entries` and that records every killed id.
    private func recordingClient(
        entries: [ZmxSessionListParser.Entry]?,
        killed: LockedBox<[String]>
    ) -> ZmxClient {
        ZmxClient(
            executableURL: { URL(fileURLWithPath: "/fake/zmx") },
            isBundled: { true },
            killSession: { id in killed.mutate { $0.append(id) } },
            killRemoteSession: { _, _ in },
            remoteForegroundComms: { _ in nil },
            listSessionsWithClients: { entries },
            sessionLeaderPIDs: { [:] }
        )
    }

    @Test
    func reapsOnlyUnclaimedDetachedSessions() async {
        let killed = LockedBox<[String]>([])
        let knownName = ZmxSessionName.make(projectName: "proj", paneSessionID: UUID())
        let client = recordingClient(
            entries: [
                .init(name: knownName, clients: 0), // claimed → spare
                .init(name: "macterm-orphan", clients: 0), // unclaimed → reap
                .init(name: "macterm-attached", clients: 1), // attached → spare
                .init(name: "supa-foreign", clients: 0), // foreign prefix → spare
            ],
            killed: killed
        )
        await client.reapOrphans(knownSessionNames: [knownName])
        #expect(killed.value == ["macterm-orphan"])
    }

    @Test
    func failedProbeReapsNothing() async {
        let killed = LockedBox<[String]>([])
        // nil listing = probe failed/unavailable → never reap.
        let client = recordingClient(entries: nil, killed: killed)
        await client.reapOrphans(knownSessionNames: [])
        #expect(killed.value.isEmpty)
    }
}
