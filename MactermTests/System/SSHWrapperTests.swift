import Foundation
@testable import Macterm
import Testing

struct SSHWrapperTests {
    // MARK: - parseDestination (mirrors ghostty's own ssh.zig tests)

    @Test
    func destination_from_typical_ssh_G_output() {
        let dump = "user alice\nhostname example.com\nport 22\nidentityfile ~/.ssh/id_ed25519\n"
        #expect(SSHWrapper.parseDestination(configDump: dump) == "alice@example.com")
    }

    @Test
    func destination_with_hostname_before_user() {
        let dump = "hostname example.com\nport 22\nuser alice\n"
        #expect(SSHWrapper.parseDestination(configDump: dump) == "alice@example.com")
    }

    @Test
    func destination_missing_hostname_is_nil() {
        #expect(SSHWrapper.parseDestination(configDump: "user alice\nport 22\n") == nil)
    }

    @Test
    func destination_missing_user_is_nil() {
        #expect(SSHWrapper.parseDestination(configDump: "hostname example.com\nport 22\n") == nil)
    }

    @Test
    func destination_empty_input_is_nil() {
        #expect(SSHWrapper.parseDestination(configDump: "") == nil)
    }

    @Test
    func destination_ipv6_hostname() {
        #expect(SSHWrapper.parseDestination(configDump: "user alice\nhostname ::1\n") == "alice@::1")
    }

    @Test
    func destination_first_occurrence_wins() {
        let dump = "user alice\nuser mallory\nhostname a.example\nhostname b.example\n"
        #expect(SSHWrapper.parseDestination(configDump: dump) == "alice@a.example")
    }

    // MARK: - argv construction

    @Test
    func destination_argv_inserts_G_before_user_args() {
        #expect(
            SSHWrapper.destinationArgv(ssh: "ssh", sshArgs: ["-p", "2222", "host"])
                == ["ssh", "-G", "-p", "2222", "host"]
        )
    }

    @Test
    func exec_argv_with_forwarding_sets_term_and_sendenv() {
        let argv = SSHWrapper.execArgv(ssh: "ssh", term: "xterm-ghostty", sshArgs: ["host"])
        #expect(argv == [
            "ssh",
            "-o", "SetEnv=TERM=xterm-ghostty",
            "-o", "SendEnv=COLORTERM",
            "-o", "SendEnv=TERM_PROGRAM",
            "-o", "SendEnv=TERM_PROGRAM_VERSION",
            "host",
        ])
    }

    @Test
    func exec_argv_without_forwarding_is_plain_ssh() {
        #expect(
            SSHWrapper.execArgv(ssh: "ssh", term: nil, sshArgs: ["-p", "2222", "host"])
                == ["ssh", "-p", "2222", "host"]
        )
    }

    @Test
    func install_argv_scopes_a_throwaway_control_connection() {
        let argv = SSHWrapper.installArgv(
            ssh: "ssh", controlPath: "/tmp/cp", sshArgs: ["host"], verbose: false
        )
        #expect(argv.count == 9)
        #expect(Array(argv[0 ..< 7]) == [
            "ssh",
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", "ControlPath=/tmp/cp",
        ])
        #expect(argv[7] == "host")
        #expect(argv[8] == SSHWrapper.installScript(verbose: false))
    }

    @Test
    func install_script_probes_tic_and_compiles_from_stdin() {
        let script = SSHWrapper.installScript(verbose: false)
        #expect(script.contains("command -v tic"))
        #expect(script.contains("tic -x - 2>/dev/null"))
        // Verbose keeps tic's stderr — the commonest failure — visible.
        #expect(!SSHWrapper.installScript(verbose: true).contains("tic -x - 2>/dev/null"))
        #expect(SSHWrapper.installScript(verbose: true).contains("tic -x -"))
    }

    @Test
    func install_script_survives_non_posix_login_shells() {
        // sshd hands the remote command to the LOGIN shell, so the script
        // must ship as `sh -c '<single-quote-free single-line script>'` —
        // the RemoteSpawn wire rule. Sent bare (as ghostty does), a nushell
        // login shell rejects `2>&1` and the install always fails; measured
        // against a real sshd.
        for verbose in [true, false] {
            let command = SSHWrapper.installScript(verbose: verbose)
            #expect(command.hasPrefix("sh -c '"))
            #expect(command.hasSuffix("'"))
            let inner = command.dropFirst("sh -c '".count).dropLast()
            #expect(!inner.contains("'"))
            #expect(!inner.contains("\n"))
        }
    }

    // MARK: - shared contract with the app side

    @Test
    func entry_name_matches_remote_terminfo() {
        // One promise about what our pinned libghostty supports, whether the
        // ssh is user-typed (SSHWrapper) or Macterm-owned (RemoteTerminfo).
        #expect(SSHWrapper.entryName == RemoteTerminfo.entryName)
        #expect(SSHWrapper.entryName == "xterm-ghostty")
    }

    @Test
    func source_argv_keeps_extended_capabilities() {
        // `-x` on infocmp must match the `-x` the remote tic gets, or the
        // Tc/RGB capabilities silently drop out of the installed entry.
        #expect(SSHWrapper.sourceArgv() == ["-x", "xterm-ghostty"])
        #expect(SSHWrapper.installScript(verbose: false).contains("tic -x -"))
    }

    // MARK: - bundled DB resolution

    @Test
    func bundled_db_resolves_beside_the_binary() {
        let db = SSHWrapper.bundledTerminfoDirectory(
            executablePath: "/Applications/Macterm.app/Contents/Resources/bin/macterm",
            exists: { $0 == "/Applications/Macterm.app/Contents/Resources/terminfo/78/xterm-ghostty" }
        )
        #expect(db == "/Applications/Macterm.app/Contents/Resources/terminfo")
    }

    @Test
    func bundled_db_requires_the_hashed_entry_itself() {
        // A present directory without the entry (half-copied bundle) must
        // fall through to the inherited environment, not pin a dead TERMINFO.
        let db = SSHWrapper.bundledTerminfoDirectory(
            executablePath: "/Applications/Macterm.app/Contents/Resources/bin/macterm",
            exists: { $0 == "/Applications/Macterm.app/Contents/Resources/terminfo" }
        )
        #expect(db == nil)
    }

    // MARK: - install cache

    @Test
    func version_key_is_stable_and_content_addressed() {
        let a = SSHWrapper.versionKey(source: Data("entry-v1".utf8))
        let b = SSHWrapper.versionKey(source: Data("entry-v1".utf8))
        let c = SSHWrapper.versionKey(source: Data("entry-v2".utf8))
        #expect(a == b)
        #expect(a != c)
        #expect(a.count == 16)
    }

    @Test
    func cache_round_trip() {
        var text = ""
        text = SSHWrapper.cacheUpdating(cacheText: text, destination: "alice@a.example", version: "v1")
        text = SSHWrapper.cacheUpdating(cacheText: text, destination: "bob@b.example", version: "v1")
        #expect(SSHWrapper.cacheContains(cacheText: text, destination: "alice@a.example", version: "v1"))
        #expect(SSHWrapper.cacheContains(cacheText: text, destination: "bob@b.example", version: "v1"))
        #expect(!SSHWrapper.cacheContains(cacheText: text, destination: "carol@c.example", version: "v1"))
    }

    @Test
    func cache_misses_on_version_change_and_update_replaces() {
        // A GhosttyKit bump changes the bundled entry and every destination
        // must reinstall once — the stale line is replaced, not duplicated.
        var text = SSHWrapper.cacheUpdating(cacheText: "", destination: "alice@a.example", version: "v1")
        #expect(!SSHWrapper.cacheContains(cacheText: text, destination: "alice@a.example", version: "v2"))
        text = SSHWrapper.cacheUpdating(cacheText: text, destination: "alice@a.example", version: "v2")
        #expect(SSHWrapper.cacheContains(cacheText: text, destination: "alice@a.example", version: "v2"))
        #expect(!SSHWrapper.cacheContains(cacheText: text, destination: "alice@a.example", version: "v1"))
        #expect(text == "alice@a.example\tv2\n")
    }

    @Test
    func cache_ignores_malformed_lines() {
        let text = "garbage\n\nalice@a.example\tv1\n"
        #expect(SSHWrapper.cacheContains(cacheText: text, destination: "alice@a.example", version: "v1"))
        #expect(!SSHWrapper.cacheContains(cacheText: text, destination: "garbage", version: "v1"))
    }
}
