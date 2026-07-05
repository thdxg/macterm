import Foundation
@testable import Macterm
import Testing

struct RemoteSpawnTests {
    private let remote = ProjectPath.remote(user: nil, host: "devbox", directory: "~/dev/api")

    // MARK: - Pane command

    @Test
    func pane_command_execs_zmx_after_guarding_zmx_and_cd() {
        // The remote side is `sh -c '<script>'` with a single-quote-free
        // script — the one form every login shell (bash/zsh/fish/nu)
        // tokenizes identically before POSIX sh takes over.
        let cmd = try? #require(RemoteSpawn.paneCommand(remote: remote, sessionName: "macterm-api-abc123"))
        // Missing zmx / bad cwd must NOT close the pane — they drop into a
        // login shell with a diagnostic instead of exiting.
        #expect(cmd?.contains("command -v zmx") == true)
        #expect(cmd?.contains("zmx not found in PATH") == true)
        #expect(cmd?.contains("cannot cd to") == true)
        #expect(cmd?.contains("exec ${SHELL:-/bin/sh}") == true)
        // Happy path still execs the attach into the declared dir.
        #expect(cmd?.contains("cd ~/\"dev/api\"") == true)
        #expect(cmd?.contains("exec zmx attach \"macterm-api-abc123\"") == true)
    }

    @Test
    func pane_command_with_explicit_zmx_path_skips_the_presence_guard() {
        // An explicit path is used verbatim and needs no `command -v` guard —
        // its own failure surfaces as zmx's error, still visible in the pane.
        let cmd = try? #require(RemoteSpawn.paneCommand(
            remote: remote, sessionName: "macterm-api-abc123", zmxPath: "~/bin/zmx"
        ))
        #expect(cmd?.contains("command -v zmx") == false)
        #expect(cmd?.contains("exec \"~/bin/zmx\" attach \"macterm-api-abc123\"") == true)
    }

    @Test
    func pane_command_script_is_single_quote_free() {
        // Single quotes in the script would break the `sh -c '<script>'`
        // wrapper on a non-POSIX login shell.
        let cmd = RemoteSpawn.paneCommand(remote: remote, sessionName: "macterm-api-abc123")
        // The only single quotes are the two that wrap the sh -c argument
        // (the outer ssh quoting escapes them as '\'').
        #expect(cmd?.contains("'\\''") == true)
    }

    @Test
    func pane_command_includes_user_in_destination() {
        let cmd = RemoteSpawn.paneCommand(
            remote: .remote(user: "deploy", host: "10.0.0.5", directory: "/srv/app"),
            sessionName: "macterm-app-ff00"
        )
        #expect(cmd?.contains("ssh -t 'deploy@10.0.0.5'") == true)
        #expect(cmd?.contains("cd \"/srv/app\"") == true)
    }

    @Test
    func pane_command_has_no_batchmode_so_auth_can_prompt() {
        let cmd = RemoteSpawn.paneCommand(remote: remote, sessionName: "macterm-api-abc123")
        #expect(cmd?.contains("BatchMode") == false)
    }

    @Test
    func pane_command_is_nil_for_local_paths() {
        #expect(RemoteSpawn.paneCommand(remote: .local("/a/b"), sessionName: "s") == nil)
    }

    // MARK: - Background op argv

    @Test
    func op_argv_uses_batchmode_and_connect_timeout() {
        let argv = RemoteSpawn.opArgv(remote: remote, zmxArguments: ["kill", "macterm-api-abc123"])
        #expect(argv == [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "devbox",
            "\(RemoteSpawn.remoteShell) " + RemoteSpawn.shellQuote(
                RemoteSpawn.remoteEnvPreamble + "exec zmx \"kill\" \"macterm-api-abc123\""
            ),
        ])
        // sh -c (NOT sh -lc): the login flag is unportable — older dash rejects
        // it and drops to an interactive shell.
        #expect(RemoteSpawn.remoteShell == "sh -c")
    }

    @Test
    func op_argv_uses_explicit_zmx_path_verbatim() {
        let argv = RemoteSpawn.opArgv(
            remote: remote, zmxArguments: ["kill", "s"], zmxPath: "~/bin/zmx"
        )
        #expect(argv?.last?.contains("exec \"~/bin/zmx\" \"kill\" \"s\"") == true)
    }

    @Test
    func op_argv_is_nil_for_local_paths() {
        #expect(RemoteSpawn.opArgv(remote: .local("/a"), zmxArguments: ["ls"]) == nil)
    }

    // MARK: - Foreground probe

    @Test
    func probe_argv_is_noninteractive_and_carries_the_script() {
        let argv = try? #require(RemoteSpawn.foregroundProbeArgv(remote: remote))
        #expect(argv?.prefix(4) == ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5"])
        #expect(argv?.dropFirst(4).first == "devbox")
        let expectedScript = RemoteSpawn.remoteEnvPreamble
            + RemoteSpawn.foregroundProbeScript.replacingOccurrences(of: "<ZMX>", with: "zmx")
        #expect(argv?.last == "\(RemoteSpawn.remoteShell) " + RemoteSpawn.shellQuote(expectedScript))
        #expect(RemoteSpawn.foregroundProbeScript.contains("tpgid"))
        // The sh -c wrapper only survives arbitrary login shells while the
        // script stays free of single quotes.
        #expect(!RemoteSpawn.foregroundProbeScript.contains("'"))
        #expect(RemoteSpawn.foregroundProbeArgv(remote: .local("/a")) == nil)
    }

    @Test
    func probe_argv_substitutes_explicit_zmx_path() {
        let argv = RemoteSpawn.foregroundProbeArgv(remote: remote, zmxPath: "/opt/zmx")
        #expect(argv?.last?.contains("\"/opt/zmx\" ls") == true)
    }

    // MARK: - Quoting

    @Test
    func shell_quote_survives_spaces_dollars_and_quotes() {
        #expect(RemoteSpawn.shellQuote("plain") == "'plain'")
        #expect(RemoteSpawn.shellQuote("with space") == "'with space'")
        #expect(RemoteSpawn.shellQuote("$HOME") == "'$HOME'")
        #expect(RemoteSpawn.shellQuote("it's") == "'it'\\''s'")
    }

    @Test
    func remote_directory_keeps_tilde_expandable() {
        // A quoted tilde is a literal directory named "~" — the tilde segment
        // must stay bare so sh expands it. Double quotes, so the containing
        // sh -c script stays single-quote-free.
        #expect(RemoteSpawn.quoteRemoteDirectory("~") == "~")
        #expect(RemoteSpawn.quoteRemoteDirectory("~/dev/api") == "~/\"dev/api\"")
        #expect(RemoteSpawn.quoteRemoteDirectory("~/dir with space") == "~/\"dir with space\"")
        #expect(RemoteSpawn.quoteRemoteDirectory("~deploy/app") == "~deploy/\"app\"")
        #expect(RemoteSpawn.quoteRemoteDirectory("~deploy") == "~deploy")
    }

    @Test
    func remote_directory_quotes_plain_paths_whole() {
        #expect(RemoteSpawn.quoteRemoteDirectory("/srv/my app") == "\"/srv/my app\"")
        #expect(RemoteSpawn.quoteRemoteDirectory("work/api") == "\"work/api\"")
    }

    @Test
    func posix_double_quote_escapes_shell_metacharacters() {
        #expect(RemoteSpawn.posixDoubleQuote("plain") == "\"plain\"")
        #expect(RemoteSpawn.posixDoubleQuote("a$b") == "\"a\\$b\"")
        #expect(RemoteSpawn.posixDoubleQuote("a\"b") == "\"a\\\"b\"")
        #expect(RemoteSpawn.posixDoubleQuote("a`b") == "\"a\\`b\"")
        #expect(RemoteSpawn.posixDoubleQuote("a\\b") == "\"a\\\\b\"")
    }

    // MARK: - Destination

    @Test
    func destination_composes_user_and_host() {
        #expect(RemoteSpawn.destination(user: nil, host: "devbox") == "devbox")
        #expect(RemoteSpawn.destination(user: "me", host: "devbox") == "me@devbox")
    }
}
