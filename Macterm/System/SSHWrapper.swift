import CryptoKit
import Foundation

/// The engine behind ghostty's shell-integration `ssh` wrapper — the
/// `ghostty +ssh` CLI action reimplemented natively, surfaced as `macterm ssh`
/// and reached through the `ghostty` shim the build bundles at
/// `Contents/Resources/ssh-bridge/ghostty` (`scripts/ghostty-shim.sh`).
///
/// Why this exists: the bundled shell-integration scripts wrap `ssh` as
/// `"$GHOSTTY_BIN_DIR/ghostty" +ssh [--forward-env=false] [--terminfo=false]
/// -- "$@"` in every shell they support. Macterm ships no ghostty CLI, and
/// used to detect an installed Ghostty.app and either borrow its CLI (by
/// pointing `GHOSTTY_BIN_DIR` at it) or force the ssh features off. Pointing
/// `GHOSTTY_BIN_DIR` at our own `+ssh` implementation instead removes that
/// dependency outright: `ssh-env`/`ssh-terminfo` now work on a machine that
/// has never seen Ghostty.app, against the terminfo entry OUR pinned
/// libghostty actually supports (see `MactermConfig.regenerate`).
///
/// What `+ssh` does (mirroring ghostty's `src/cli/ssh.zig` on the pinned
/// fork release):
///   1. Resolve the destination via `ssh -G` (`user`/`hostname` keys).
///   2. Unless cached, install the bundled `xterm-ghostty` terminfo on the
///      destination — `infocmp -x` piped to a remote `tic -x -` over a
///      throwaway `ControlMaster` connection — and cache success.
///   3. Run the real ssh with `-o SetEnv=TERM=…` (`xterm-ghostty` when the
///      entry is known installed, else `xterm-256color`) plus `SendEnv`
///      requests for `COLORTERM`/`TERM_PROGRAM`/`TERM_PROGRAM_VERSION`.
///
/// This file is pure selection logic — argv/script/cache-text construction
/// with no process spawns or file I/O — because it is compiled into BOTH the
/// app target and the `MactermCLI` tool target (the `ControlProtocol`
/// pattern), and unit-tested through the app module. Keep it free of
/// app-only dependencies (`os.Logger`, `appBundleID`, AppKit).
///
/// The remote-project counterpart is `RemoteTerminfo`, which installs the
/// same entry for panes whose ssh connection Macterm itself owns; this type
/// serves the `ssh` the *user* types into a local pane's shell. The two share
/// `entryName` so they can never promise different entries.
enum SSHWrapper {
    /// The terminfo entry installed and promised via `SetEnv=TERM=`. Single
    /// source of truth — `RemoteTerminfo.entryName` delegates here.
    static let entryName = "xterm-ghostty"

    /// TERM promised when the entry isn't known to resolve on the host: a
    /// name every terminfo DB ships, so TUIs always start.
    static let fallbackTerm = "xterm-256color"

    /// macOS always ships infocmp; no probe, no fallback (macOS 14+).
    static let infocmpPath = "/usr/bin/infocmp"

    /// argv (after `infocmp`) reading the bundled entry as `tic`-compilable
    /// source. `-x` keeps extended capabilities (`Tc` among them — the whole
    /// point) and must match the flag the remote `tic` gets.
    static func sourceArgv() -> [String] {
        ["-x", entryName]
    }

    /// The bundled compiled terminfo DB, resolved relative to the CLI binary:
    /// the CLI lives at `Contents/Resources/bin/macterm` and the DB at its
    /// sibling `Contents/Resources/terminfo` (the layout libghostty's own
    /// TERMINFO derivation requires — see `GhosttyResourceResolver`). Checked
    /// by the presence of the hashed entry itself (`78/xterm-ghostty`,
    /// `78` = 0x78 = "x" in the macOS hashed layout), not just the directory,
    /// so a half-copied bundle falls through. nil when the binary runs from
    /// outside a bundle (tests, a bare build product); the caller then leaves
    /// the environment alone, and inside a pane the inherited `TERMINFO` —
    /// which libghostty pins to this same DB at shell spawn — still resolves.
    static func bundledTerminfoDirectory(
        executablePath: String,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let binDir = (executablePath as NSString).deletingLastPathComponent
        let db = ((binDir as NSString)
            .appendingPathComponent("../terminfo") as NSString).standardizingPath
        let entry = (db as NSString).appendingPathComponent("78/\(entryName)")
        return exists(entry) ? db : nil
    }

    /// argv resolving the destination: `ssh -G <args>` prints the effective
    /// config (aliases expanded, `~/.ssh/config` applied) without connecting.
    static func destinationArgv(ssh: String, sshArgs: [String]) -> [String] {
        [ssh, "-G"] + sshArgs
    }

    /// Parse `ssh -G` output for the `user` and `hostname` keys and return
    /// `user@hostname` — the cache key and the name shown while installing.
    /// nil when either is missing (mirrors ghostty: skip the install rather
    /// than guess).
    static func parseDestination(configDump: String) -> String? {
        var user: String?
        var host: String?
        for line in configDump.split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = line[line.startIndex ..< space]
            let value = String(line[line.index(after: space)...])
            guard !value.isEmpty else { continue }
            if key == "user", user == nil { user = value }
            if key == "hostname", host == nil { host = value }
            if user != nil, host != nil { break }
        }
        guard let user, let host else { return nil }
        return "\(user)@\(host)"
    }

    /// The remote install script, byte-for-byte ghostty's: probe for `tic`,
    /// make `~/.terminfo` (where an unprivileged `tic` compiles to), compile
    /// from stdin. Verbose keeps tic's stderr — the commonest failure source —
    /// visible; quiet discards it.
    static func installScript(verbose: Bool) -> String {
        let tic = verbose ? "tic -x -" : "tic -x - 2>/dev/null"
        return """
        command -v tic >/dev/null 2>&1 || exit 1
        mkdir -p ~/.terminfo 2>/dev/null && \(tic) && exit 0
        exit 1
        """
    }

    /// argv installing the terminfo source (piped to stdin) on the remote,
    /// over an SSH ControlMaster scoped to this single install:
    /// `ControlMaster=yes` makes this client the master, `ControlPersist=no`
    /// tears it down on exit so no socket lingers. The user's own ssh args
    /// ride along so port/identity/alias config all apply — meaning this
    /// connection can prompt for auth like the real one (deliberately not
    /// `BatchMode`: it IS the user's first connection, interactively watched).
    ///
    /// Known upstream limitation mirrored as-is: when `sshArgs` already ends
    /// in a remote command (`ssh host uptime`), ssh concatenates our script
    /// onto it and the install fails harmlessly into the `xterm-256color`
    /// fallback — the wrapper only ever really installs on interactive
    /// connections.
    static func installArgv(
        ssh: String, controlPath: String, sshArgs: [String], verbose: Bool
    ) -> [String] {
        [
            ssh,
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", "ControlPath=\(controlPath)",
        ] + sshArgs + [installScript(verbose: verbose)]
    }

    /// The final argv the wrapper becomes. With `term` set (forward-env on):
    /// `SetEnv=TERM=…` — the one variable ssh carries on the pty request, so
    /// no server-side `AcceptEnv` can drop it (OpenSSH ≥ 8.7) — plus `SendEnv`
    /// requests the server may filter; harmless when it does. With `term` nil
    /// (forward-env off): plain ssh, untouched.
    static func execArgv(ssh: String, term: String?, sshArgs: [String]) -> [String] {
        guard let term else { return [ssh] + sshArgs }
        return [
            ssh,
            "-o", "SetEnv=TERM=\(term)",
            "-o", "SendEnv=COLORTERM",
            "-o", "SendEnv=TERM_PROGRAM",
            "-o", "SendEnv=TERM_PROGRAM_VERSION",
        ] + sshArgs
    }

    // MARK: - Install cache

    /// What identifies "the entry currently bundled": a digest of the exact
    /// source `infocmp` produced. ghostty keys its cache on its compile-time
    /// version; we have no such constant — the entry arrives with each pinned
    /// GhosttyKit release — so the honest key is the content itself. A
    /// GhosttyKit bump that changes the entry changes the key, and every
    /// destination reinstalls once.
    static func versionKey(source: Data) -> String {
        SHA256.hash(data: source).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Cache file: one `<destination>\t<version>` line per host, in
    /// `~/Library/Caches` — shared across debug/release builds on purpose,
    /// because it records per-host state, not app state.
    static func cacheFilePath(home: String) -> String {
        home + "/Library/Caches/macterm/ssh-terminfo"
    }

    static func cacheContains(cacheText: String, destination: String, version: String) -> Bool {
        cacheText.split(separator: "\n").contains { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            return parts.count == 2 && parts[0] == destination[...] && parts[1] == version[...]
        }
    }

    /// The cache text with `destination` recorded at `version`, replacing any
    /// stale line for the same destination.
    static func cacheUpdating(cacheText: String, destination: String, version: String) -> String {
        var lines = cacheText.split(separator: "\n").filter { line in
            line.split(separator: "\t", maxSplits: 1).first != destination[...]
        }.map(String.init)
        lines.append("\(destination)\t\(version)")
        return lines.joined(separator: "\n") + "\n"
    }
}
