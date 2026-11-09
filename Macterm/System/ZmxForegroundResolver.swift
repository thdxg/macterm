import Darwin
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "ZmxForeground")

/// Translates a wrapped surface's session name into the pid of the *real*
/// foreground process — the shell or program the user is actually looking at.
///
/// Why this is needed: a wrapped surface's shell runs in its v2 **session**
/// process, a process tree detached from the `zmx connect` **client** that
/// libghostty reports as the surface's foreground pid. So `ProcessInspector`,
/// reading libghostty's pid, sees `zmx` for every pane — breaking tab names
/// and layout `run:` capture. The session side is reachable only by name.
///
/// Resolution: the server's `session.list` maps `sessionName → shell pid
/// and pty` (the `login`/shell process that the session started). The
/// shell's controlling tty's foreground process group is the true
/// foreground — NOT the deepest child (a language server spawned by an
/// editor is a deeper leaf than the editor the user sees). This mirrors how
/// libghostty / tmux resolve the foreground on the client side; we just do
/// it against the session's pty.
///
/// A session's shell pid and pty are **stable for its lifetime** — so the
/// map only needs refreshing on session lifecycle events (spawn, kill,
/// reattach) plus a slow reconcile. `ZmxRefreshGate` owns that policy;
/// per-tick work here is one cheap syscall (the `kinfo_proc` sysctl).
enum ZmxForegroundResolver {
    struct Entry: Equatable {
        let leaderPID: pid_t
        /// The session's pty path, as the server reports it.
        let ttyPath: String?
    }

    /// Cached `macterm-…` name → session shell (pid + tty). Guarded by an
    /// unfair lock; written by the off-main refresh, read on the main actor.
    private static let cache = OSAllocatedUnfairLock<[String: Entry]>(initialState: [:])

    /// Replace the cache from a fresh `session.list`. Only running sessions
    /// with a shell pid are kept.
    static func updateCache(_ sessions: [LocalSession]) {
        let entries = entries(from: sessions)
        cache.withLock { $0 = entries }
        logger.debug("updateCache: \(entries.count, privacy: .public) session(s)")
    }

    /// The cache entries of a listing. Pure.
    static func entries(from sessions: [LocalSession]) -> [String: Entry] {
        var entries: [String: Entry] = [:]
        for session in sessions where session.isRunning {
            guard let pid = session.shellPID else { continue }
            entries[session.name] = Entry(leaderPID: pid, ttyPath: session.ttyPath)
        }
        return entries
    }

    /// The pid of the real foreground process for `sessionName`, or nil when
    /// the session isn't cached (not zmx-wrapped, or not refreshed yet).
    /// A dead leader (stale cache after a kill from outside) is evicted so
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

    /// The session's pty path for `sessionName`, or nil when uncached. Used
    /// by `ProcessInspector.terminalInputIsRaw` — raw-mode detection must probe
    /// the session's pty, because the `zmx connect` client keeps the
    /// client-side pty raw permanently.
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
}

/// Pure refresh policy for the resolver cache: refresh on session lifecycle
/// events (spawn/kill/reattach — the only times a leader pid can change) and
/// on a slow reconcile TTL as a safety net against drift from kills
/// outside the app. Owned by `AppState`, consulted inside the poll tick; value
/// type with an injected clock in the `PollCadence` style.
struct ZmxRefreshGate {
    static let reconcileInterval: TimeInterval = 30

    private var invalidated = true
    private var lastRefreshAt: Date?

    /// A session was created, killed, or reattached — the map is stale.
    mutating func noteSessionLifecycle() {
        invalidated = true
    }

    /// Whether the caller should list the sessions now. Returns true at most once
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
