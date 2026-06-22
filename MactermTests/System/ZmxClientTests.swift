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

struct ZmxSessionIDTests {
    @Test
    func formatsLowercasedWithPrefix() throws {
        let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        #expect(ZmxSessionID.make(surfaceID: id) == "macterm-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
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
    func interactiveSurfaceGetsArgvWrapperAndNilCommand() {
        let (command, wrapper) = ZmxAttach.resolveLaunch(
            executablePath: "/path/to/zmx", sessionID: "macterm-1", command: nil
        )
        #expect(command == nil)
        #expect(wrapper == ["/path/to/zmx", "attach", "macterm-1"])
    }

    @Test
    func blankCommandIsTreatedAsInteractive() {
        let (command, wrapper) = ZmxAttach.resolveLaunch(
            executablePath: "/path/to/zmx", sessionID: "macterm-1", command: "   "
        )
        #expect(command == nil)
        #expect(wrapper == ["/path/to/zmx", "attach", "macterm-1"])
    }

    @Test
    func declaredCommandGetsShWrappedStringNoWrapper() {
        let (command, wrapper) = ZmxAttach.resolveLaunch(
            executablePath: "/path/to/zmx", sessionID: "macterm-1", command: "npm run dev"
        )
        #expect(command == "'/path/to/zmx' attach macterm-1 /bin/sh -c 'npm run dev'")
        #expect(wrapper.isEmpty)
    }

    @Test
    func noExecutableFallsThroughToRawCommandNoZmx() {
        let (command, wrapper) = ZmxAttach.resolveLaunch(
            executablePath: nil, sessionID: "macterm-1", command: "npm run dev"
        )
        #expect(command == "npm run dev")
        #expect(wrapper.isEmpty)
    }

    @Test
    func singleQuotesInCommandAreEscaped() {
        let (command, _) = ZmxAttach.resolveLaunch(
            executablePath: "/zmx", sessionID: "s", command: "echo 'hi'"
        )
        // POSIX single-quote escaping: ' becomes '\''
        #expect(command == "'/zmx' attach s /bin/sh -c 'echo '\\''hi'\\'''")
    }
}
