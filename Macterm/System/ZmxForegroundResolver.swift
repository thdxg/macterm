import Darwin
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ZmxForeground")

/// Translates a zmx-wrapped surface's session id into the pid of the *real*
/// foreground process — the shell or program the user is actually looking at.
///
/// Why this is needed: a wrapped surface's shell runs under the zmx **daemon**,
/// a process tree completely detached from the `zmx attach` **client** that
/// libghostty reports as the surface's foreground pid. So `ProcessInspector`,
/// reading libghostty's pid, sees `zmx` for every pane — breaking tab names and
/// layout `run:` capture. The daemon side is reachable only by session id.
///
/// Resolution: `zmx ls` maps `sessionID → daemon session-leader pid` (the
/// `login`/shell process the daemon spawned). The leader's controlling tty's
/// foreground process group (`tcgetpgrp`) is the true foreground — NOT the
/// deepest child (a language server spawned by an editor is a deeper leaf than
/// the editor the user sees). This mirrors how libghostty / tmux resolve the
/// foreground on the client side; we just do it against the daemon's pty.
///
/// `zmx ls` is a subprocess, far too costly to run per-pane on the ~250ms
/// foreground poll, so the `sessionID → leaderPID` map is **cached** and
/// refreshed once per poll tick (one `zmx ls` total, not per pane). Daemon
/// leader pids are stable for a session's lifetime, so cache staleness between
/// ticks is harmless.
enum ZmxForegroundResolver {
    /// Cached `macterm-<uuid>` → daemon session-leader pid. Guarded by an unfair
    /// lock; written by `refresh` (off the poll), read by `ProcessInspector` on
    /// the main actor.
    private static let cache = OSAllocatedUnfairLock<[String: pid_t]>(initialState: [:])

    /// Replace the cached session→leader-pid map. Call once per foreground-poll
    /// tick with a freshly parsed `zmx ls` listing.
    static func updateCache(_ map: [String: pid_t]) {
        cache.withLock { $0 = map }
    }

    /// The pid of the real foreground process for `sessionID`, or nil when the
    /// session isn't in the cache (not yet seen, or not zmx-wrapped). Resolves
    /// the daemon leader's pty foreground process group.
    static func foregroundPID(sessionID: String) -> pid_t? {
        guard let leaderPID = cache.withLock({ $0[sessionID] }) else { return nil }
        guard let tty = ttyPath(pid: leaderPID) else { return nil }
        let fd = open(tty, O_RDONLY | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let pgrp = tcgetpgrp(fd)
        guard pgrp > 0 else { return nil }
        return pgrp
    }

    /// The controlling-tty device path of `pid` (e.g. `/dev/ttys083`), or nil.
    /// `proc_pidinfo(PROC_PIDTBSDINFO)` gives the tty's device number; map it to
    /// a path via `devname`.
    private static func ttyPath(pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard ret == size else { return nil }
        let dev = info.e_tdev
        guard dev != 0, dev != UInt32.max else { return nil }
        guard let name = devname(dev_t(bitPattern: dev), S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }
}

extension ZmxForegroundResolver {
    /// Parse a `zmx ls` listing into a `sessionName → leaderPID` map. Reuses the
    /// existing `ZmxSessionListParser` for names and extracts the `pid=` field.
    /// Only `macterm-` sessions with a readable pid are included.
    static func parseLeaderPIDs(_ stdout: String) -> [String: pid_t] {
        var map: [String: pid_t] = [:]
        for line in stdout.split(whereSeparator: \.isNewline) {
            var trimmed = Substring(line)
            if trimmed.hasPrefix("→ ") { trimmed = trimmed.dropFirst(2) }
            while trimmed.first?.isWhitespace == true {
                trimmed = trimmed.dropFirst()
            }
            var name: String?
            var pid: pid_t?
            for field in trimmed.split(separator: "\t") {
                guard let sep = field.firstIndex(of: "=") else { continue }
                let key = field[field.startIndex ..< sep]
                let value = field[field.index(after: sep)...]
                if key == "name" { name = String(value) }
                if key == "pid" { pid = Int32(value) }
            }
            if let name, name.hasPrefix(ZmxSessionID.prefix), let pid { map[name] = pid }
        }
        return map
    }
}
