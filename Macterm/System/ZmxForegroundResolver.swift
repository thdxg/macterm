import Darwin
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ZmxForeground")

/// Translates a zmx-wrapped surface's session name into the pid of the *real*
/// foreground process — the shell or program the user is actually looking at.
///
/// Why this is needed: a wrapped surface's shell runs under the zmx **daemon**,
/// a process tree completely detached from the `zmx attach` **client** that
/// libghostty reports as the surface's foreground pid. So `ProcessInspector`,
/// reading libghostty's pid, sees `zmx` for every pane — breaking tab names and
/// layout `run:` capture. The daemon side is reachable only by session name.
///
/// Resolution: `zmx ls` maps `sessionName → daemon session-leader pid` (the
/// `login`/shell process the daemon spawned). The leader's controlling tty's
/// foreground process group (`tcgetpgrp`) is the true foreground — NOT the
/// deepest child (a language server spawned by an editor is a deeper leaf than
/// the editor the user sees). This mirrors how libghostty / tmux resolve the
/// foreground on the client side; we just do it against the daemon's pty.
///
/// `zmx ls` is a fork/exec, far too costly for the foreground poll, and daemon
/// leader pids are **stable for a session's lifetime** — so the name→leader map
/// only needs refreshing on session lifecycle events (spawn/kill/reattach) plus
/// a slow reconcile. `ZmxRefreshGate` owns that policy; per-tick work here is
/// two cheap syscalls (`kill(pid, 0)` liveness + `tcgetpgrp`).
enum ZmxForegroundResolver {
    struct Entry {
        let leaderPID: pid_t
        /// The daemon-side pty path, resolved ONCE per refresh: `devname` falls
        /// back to a full /dev scan (readdir + lstat per node) whenever the
        /// dev_t misses its static cache, which pty slaves reliably do. Doing
        /// that per foreground refresh on the main thread saturated the render
        /// loop (observed: app wedged at ~90% CPU inside devname_r). A
        /// session's leader keeps its tty for life, so resolve off-main here
        /// and never again.
        let ttyPath: String?
    }

    /// Cached `macterm-…` name → daemon leader (pid + tty). Guarded by an
    /// unfair lock; written by the off-main refresh, read on the main actor.
    private static let cache = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    /// Replace the cache from a fresh `zmx ls`. Called OFF-MAIN: the per-pid
    /// tty resolution below is the expensive devname path.
    static func updateCache(_ map: [String: pid_t]) {
        let entries = map.mapValues { Entry(leaderPID: $0, ttyPath: ttyPath(pid: $0)) }
        cache.withLock { $0 = entries }
        logger.debug("updateCache: \(entries.count, privacy: .public) session(s)")
    }

    /// The pid of the real foreground process for `sessionName`, or nil when
    /// the session isn't cached (not zmx-wrapped, or not refreshed yet).
    /// A dead leader (stale cache after an external `zmx kill`) is evicted so
    /// callers fall back to the client-side pid until the next refresh.
    ///
    /// The foreground group comes from `kinfo_proc.kp_eproc.e_tpgid` — the
    /// controlling tty's foreground process-group id, read via sysctl on the
    /// leader. This is how `ps` computes its `+` flag and how tmux resolves
    /// foregrounds on macOS. Notably NOT `tcgetpgrp`: that ioctl is limited
    /// to the caller's own controlling terminal (ENOTTY on any other pty),
    /// and `proc_pidinfo` can't be used either — the leader is root's
    /// `/usr/bin/login`, unreadable across uids. The sysctl works for both.
    static func foregroundPID(sessionName: String) -> pid_t? {
        guard let leaderPID = cache.withLock({ $0[sessionName]?.leaderPID }) else { return nil }
        guard let info = kinfoProc(pid: leaderPID) else {
            cache.withLock { $0[sessionName] = nil }
            logger.debug("resolver: leader \(leaderPID, privacy: .public) gone, evicted")
            return nil
        }
        let tpgid = info.kp_eproc.e_tpgid
        guard tpgid > 0 else {
            logger.debug("resolver: leader \(leaderPID, privacy: .public) has no foreground pgrp")
            return nil
        }
        return tpgid
    }

    /// The daemon-side pty path for `sessionName`, or nil when uncached. Used
    /// by `ProcessInspector.terminalInputIsRaw` — raw-mode detection must probe
    /// the daemon's pty, because the `zmx attach` client keeps the client-side
    /// pty raw permanently.
    static func daemonTTYPath(sessionName: String) -> String? {
        cache.withLock { $0[sessionName]?.ttyPath }
    }

    /// The kinfo_proc for `pid` via `sysctl(KERN_PROC_PID)`, or nil when the
    /// process is gone. Used instead of `proc_pidinfo` throughout: the
    /// daemon's session leader is root's `/usr/bin/login`, and proc_pidinfo
    /// refuses other-uid processes, while the kinfo sysctl is cross-user
    /// (it's what `ps` uses).
    private static func kinfoProc(pid: pid_t) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        // A reaped pid yields a zeroed struct rather than an error.
        guard info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    /// The controlling-tty device path of `pid` (e.g. `/dev/ttys083`), or nil.
    private static func ttyPath(pid: pid_t) -> String? {
        guard let info = kinfoProc(pid: pid) else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != 0, dev != -1 else { return nil }
        guard let name = devname(dev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }
}

extension ZmxForegroundResolver {
    /// Parse a `zmx ls` listing into a `sessionName → leaderPID` map. Only
    /// `macterm-` sessions with a readable pid are included.
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
            if let name, name.hasPrefix(ZmxSessionName.prefix), let pid { map[name] = pid }
        }
        return map
    }
}

/// Pure refresh policy for the resolver cache: refresh on session lifecycle
/// events (spawn/kill/reattach — the only times a leader pid can change) and
/// on a slow reconcile TTL as a safety net against drift from external
/// `zmx kill`s. Owned by `AppState`, consulted inside the poll tick; value
/// type with an injected clock in the `PollCadence` style.
struct ZmxRefreshGate {
    static let reconcileInterval: TimeInterval = 30

    private var invalidated = true
    private var lastRefreshAt: Date?

    /// A session was created, killed, or reattached — the map is stale.
    mutating func noteSessionLifecycle() {
        invalidated = true
    }

    /// Whether the caller should run `zmx ls` now. Returns true at most once
    /// per invalidation-or-TTL window: asking stamps the refresh, so callers
    /// must actually perform it (a failed run self-heals via the TTL).
    mutating func shouldRefresh(now: Date) -> Bool {
        let ttlElapsed = lastRefreshAt.map { now.timeIntervalSince($0) >= Self.reconcileInterval } ?? true
        guard invalidated || ttlElapsed else { return false }
        invalidated = false
        lastRefreshAt = now
        return true
    }
}
