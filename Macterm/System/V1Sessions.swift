import Darwin
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "V1Sessions")

/// Ends v1's local zmx sessions without zmx's IPC (design/008 §4, Q3 A).
///
/// v1.33.2 ships zmx 0.8.1, and the bundled zmx 1.0.1 cannot talk to a
/// daemon from before 1.0: `zmx kill` hangs until its timeout. So Macterm
/// finds each v1 daemon by its argv (`zmx __daemon <name> …`) and signals
/// it and the programs of its pane. A v2 session is `zmx __session <id>`,
/// so it never matches.
enum V1Sessions {
    /// One process of the user, from the kernel's process table.
    struct Process: Equatable {
        var pid: pid_t
        var ppid: pid_t
        /// The session of the process (`getsid`). A pane's programs share
        /// the session of the pty that the daemon opened for its shell.
        var sid: pid_t
        var argv: [String]
    }

    /// The processes to end for these session names.
    struct Targets: Equatable {
        /// The v1 daemons of the names.
        var daemons: [pid_t]
        /// The programs of their panes: every descendant of a daemon, and
        /// every process in the pty session of a daemon's child. A program
        /// that `setsid`'d away and was reparented is in neither set.
        var programs: [pid_t]
    }

    /// The v1 daemon of `argv`, or nil: `zmx __daemon <name> [-- …]`.
    static func daemonSession(argv: [String]) -> String? {
        guard argv.count >= 3, argv[1] == "__daemon",
              (argv[0] as NSString).lastPathComponent == "zmx"
        else { return nil }
        return argv[2]
    }

    static func targets(in processes: [Process], names: Set<String>) -> Targets {
        let daemons = processes.filter { process in
            daemonSession(argv: process.argv).map(names.contains) ?? false
        }
        let daemonPIDs = Set(daemons.map(\.pid))
        var children: [pid_t: [Process]] = [:]
        for process in processes {
            children[process.ppid, default: []].append(process)
        }
        // A daemon is the leader of its own session; its child's session
        // is the pane's pty.
        let paneSessions = Set(daemons.flatMap { children[$0.pid] ?? [] }.map(\.sid))
            .subtracting(daemonPIDs)
            .filter { $0 > 0 }
        var programs = Set(processes.filter { paneSessions.contains($0.sid) }.map(\.pid))
        var queue = Array(daemonPIDs)
        while let pid = queue.popLast() {
            for child in children[pid] ?? [] where !programs.contains(child.pid) {
                programs.insert(child.pid)
                queue.append(child.pid)
            }
        }
        programs.subtract(daemonPIDs)
        programs.remove(getpid())
        return Targets(daemons: daemonPIDs.sorted(), programs: programs.sorted())
    }

    /// Ends the v1 sessions of these names, and removes their sockets from
    /// `socketDir`. True only when no v1 daemon of the names runs after it.
    static func end(names: Set<String>, socketDir: String) async -> Bool {
        guard !names.isEmpty else { return true }
        let first = targets(in: snapshot(), names: names)
        if !first.daemons.isEmpty {
            logger.info(
                "Ending \(first.daemons.count, privacy: .public) v1 session(s), \(first.programs.count, privacy: .public) program(s)"
            )
            // A shell ends on SIGHUP, as when its terminal closes.
            for pid in first.programs {
                kill(pid, SIGHUP)
                kill(pid, SIGTERM)
            }
            for pid in first.daemons {
                kill(pid, SIGTERM)
            }
            let all = first.daemons + first.programs
            if await !waitUntilGone(all, timeout: .seconds(2)) {
                for pid in all where isAlive(pid) {
                    kill(pid, SIGKILL)
                }
                _ = await waitUntilGone(all, timeout: .seconds(1))
            }
        }
        let left = targets(in: snapshot(), names: names).daemons
        guard left.isEmpty else {
            logger.error("\(left.count, privacy: .public) v1 session(s) still run; trying again at the next launch")
            return false
        }
        for name in names {
            unlink("\(socketDir)/\(name)")
        }
        return true
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func waitUntilGone(_ pids: [pid_t], timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !pids.contains(where: isAlive) { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !pids.contains(where: isAlive)
    }

    /// The user's processes. argv is read only for a process whose name is
    /// `zmx`; the rest need only the tree and the session.
    static func snapshot() -> [Process] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // The table can grow between the two calls.
        size += 16 * MemoryLayout<kinfo_proc>.stride
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        let ok = table.withUnsafeMutableBytes { raw in
            sysctl(&mib, 4, raw.baseAddress, &size, nil, 0) == 0
        }
        guard ok else { return [] }
        table.removeLast(table.count - size / MemoryLayout<kinfo_proc>.stride)
        return table.compactMap { info -> Process? in
            let pid = info.kp_proc.p_pid
            guard pid > 0 else { return nil }
            let comm = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return Process(
                pid: pid,
                ppid: info.kp_eproc.e_ppid,
                sid: getsid(pid),
                argv: comm == "zmx" ? ProcessInspector.argv(pid: pid) ?? [] : []
            )
        }
    }
}
