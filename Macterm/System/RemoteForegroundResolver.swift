import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "RemoteForegroundResolver")

/// Tier-2 smart tab naming for remote panes (#104): a batched, per-host ssh
/// probe resolving every `macterm-*` session on a host to its foreground
/// process name (`RemoteSpawn.foregroundProbeScript` — the remote analogue of
/// the local session→leader→tpgid→comm pipeline).
///
/// Deliberately NOT on the local poll's cadence: the local poll bursts at
/// 250ms, which would be absurd over ssh. Each host is probed at most once
/// per `minInterval`, one ssh covers all of its sessions, overlapping probes
/// are dropped, and a failed probe degrades silently — names freeze at their
/// last-known value (tier 1, the execution-gated OSC titles, keeps working).
@MainActor
final class RemoteForegroundResolver {
    /// Minimum spacing between probes of one host. ~3s keeps names feeling
    /// live without hammering hosts that lack ControlMaster (where every
    /// probe is a full handshake).
    let minInterval: TimeInterval

    private var inflight: Set<String> = []
    private var lastProbeAt: [String: Date] = [:]

    init(minInterval: TimeInterval = 3) {
        self.minInterval = minInterval
    }

    /// Kick probes for the hosts behind `panes` (the poll passes the active
    /// project's remote panes). Per distinct ssh destination: skip when a
    /// probe is inflight or ran within `minInterval`; otherwise fire one and
    /// apply the resulting names to every passed pane on that host. `probe`
    /// is passed per call (AppState hands in the injectable
    /// `ZmxClient.remoteForegroundComms`; tests hand in a recorder).
    func refresh(
        panes: [Pane],
        probe: @escaping @Sendable (ProjectPath, String?) async -> [String: String]?,
        now: Date = Date()
    ) {
        guard !panes.isEmpty else { return }
        var specByDest: [String: ProjectPath] = [:]
        var panesByDest: [String: [Pane]] = [:]
        for pane in panes {
            guard let spec = ProjectPath.remote(from: pane.projectPath),
                  case let .remote(user, host, _) = spec
            else { continue }
            let dest = RemoteSpawn.destination(user: user, host: host)
            specByDest[dest] = spec
            panesByDest[dest, default: []].append(pane)
        }
        for (dest, spec) in specByDest {
            guard !inflight.contains(dest) else { continue }
            if let last = lastProbeAt[dest], now.timeIntervalSince(last) < minInterval { continue }
            inflight.insert(dest)
            lastProbeAt[dest] = now
            let targets = panesByDest[dest] ?? []
            // zmxPath is a host property — all panes on this dest share it.
            let zmxPath = targets.first?.remoteZmxPath
            Task {
                let map = await probe(spec, zmxPath)
                finish(dest: dest, map: map, panes: targets)
            }
        }
    }

    private func finish(dest: String, map: [String: String]?, panes: [Pane]) {
        inflight.remove(dest)
        guard let map else {
            // Unreachable/auth/timeout: names freeze at last-known. Logged
            // once per failure, never surfaced — a flaky link must not nag.
            logger.info("Remote foreground probe failed for \(dest, privacy: .public)")
            return
        }
        for pane in panes {
            pane.applyRemoteForegroundName(map[pane.sessionName])
        }
    }

    /// Parse `session<TAB>comm` probe lines into a name → comm map. Pure.
    nonisolated static func parseProbeOutput(_ stdout: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let comm = parts[1].trimmingCharacters(in: .whitespaces)
            guard name.hasPrefix("macterm-"), !comm.isEmpty else { continue }
            map[name] = comm
        }
        return map
    }
}
