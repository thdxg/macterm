import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "RemoteForegroundResolver")

/// One session's probed remote foreground: the short process name (`comm`,
/// feeds tab naming), the host's own idle verdict (`isIdle`, feeds the
/// busy-close policy), and — when the host's `ps` reported it — the
/// foreground's full command line (`args`, feeds Save Layout's `run:`
/// capture, the remote analogue of the local KERN_PROCARGS2 argv).
struct RemoteForeground: Equatable {
    let comm: String
    /// The host's idle verdict — true when the tty's foreground process
    /// group IS the session leader's (the shell owns its prompt), judged
    /// where the processes actually live so no local shell database has to
    /// recognize a remote-only login shell. nil when the probe couldn't
    /// compute one (pgid read failure, older wire format) — consumers fall
    /// back to the local shell-database heuristic.
    let isIdle: Bool?
    /// The full `ps -o args=` command line, nil when the probe line carried
    /// none. May describe a shell at its prompt — `Pane.applyRemoteForeground`
    /// decides whether it counts as a running command.
    let command: String?

    /// `isIdle` defaults to nil (no host verdict) so name+command call sites
    /// — tests, the name-only convenience — read unchanged.
    init(comm: String, isIdle: Bool? = nil, command: String?) {
        self.comm = comm
        self.isIdle = isIdle
        self.command = command
    }
}

/// One probe's result, classified so the resolver can pick the right
/// degradation. The split matters because the two failure modes want
/// opposite policies (#272): a transient failure keeps the silent per-tick
/// retry — a flaky link must recover on its own — while an authentication
/// refusal suspends the host's probes for the rest of the run, because under
/// `BatchMode` a refusal can only repeat, and with a biometric-gated key
/// (Touch ID) every attempt raises a key-provider system dialog that
/// `BatchMode` cannot suppress (it only disables ssh's own tty prompts).
enum RemoteProbeOutcome: Equatable {
    case success([String: RemoteForeground])
    /// Spawn failure, timeout, unreachable host — transient; keep retrying.
    case unreachable
    /// The host refused our non-interactive authentication.
    case authRefused

    /// Classify a failed ssh exit by its stderr. `Permission denied` is the
    /// canonical BatchMode refusal — and exactly what a cancelled Touch ID
    /// dialog produces: the key provider reports the signature failed and
    /// BatchMode blocks every interactive fallback. Anything else (timeouts,
    /// resolution failures, dropped connections) stays transient.
    static func classifyFailure(stderr: String) -> RemoteProbeOutcome {
        let authMarkers = ["Permission denied", "Too many authentication failures"]
        return authMarkers.contains(where: stderr.contains) ? .authRefused : .unreachable
    }
}

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
/// An auth-REFUSED probe suspends the host outright (see
/// `RemoteProbeOutcome`): retrying a refusal is at best pointless and at
/// worst a Touch ID dialog every 3 seconds (#272).
@MainActor
final class RemoteForegroundResolver {
    /// Minimum spacing between probes of one host. ~3s keeps names feeling
    /// live without hammering hosts that lack ControlMaster (where every
    /// probe is a full handshake).
    let minInterval: TimeInterval

    private var inflight: Set<String> = []
    private var lastProbeAt: [String: Date] = [:]
    /// Destinations whose last probe was an authentication refusal (#272):
    /// suspended for the rest of the run — every further attempt would fail
    /// the same way, or nag a biometric key's dialog every tick. In-memory
    /// only (like `RemoteTerminfo`'s attempted set): next launch tries once.
    private var authRefusedDests: Set<String> = []
    /// Panes already seen by `refresh`. A never-seen pane is the reset signal
    /// for `authRefusedDests`: it means a fresh interactive connection to the
    /// host, so a ControlMaster the user configured since now exists (probes
    /// ride it free) — and if not, the retest costs one prompt beside the
    /// pane's own instead of one per tick.
    private var seenPaneIDs: Set<UUID> = []

    /// True when no probe `Task` is outstanding. Read by tests to wait for a
    /// probe to complete deterministically — including the failure path, whose
    /// only effect is *not* changing a name, so there's no state edge to poll.
    var isIdle: Bool { inflight.isEmpty }

    init(minInterval: TimeInterval = 3) {
        self.minInterval = minInterval
    }

    /// Kick probes for the hosts behind `panes` (the poll passes the active
    /// project's remote panes). Per distinct ssh destination: skip when a
    /// probe is inflight or ran within `minInterval`; otherwise fire one and
    /// apply the resulting names to every passed pane on that host. A pane
    /// holding a boundary request (`remoteProbePending` — a command just
    /// started or finished) bypasses the interval for its host so the name
    /// updates now instead of on the next scheduled probe; the inflight
    /// guard still holds, and an unconsumed request survives to the next
    /// tick. A destination whose last probe was refused authentication is
    /// skipped entirely — boundary requests included — until a new pane on
    /// it appears (see `seenPaneIDs`). `probe` is passed per call (AppState
    /// hands in the injectable `ZmxClient.remoteForegrounds`; tests hand in
    /// a recorder).
    func refresh(
        panes: [Pane],
        probe: @escaping @Sendable (ProjectPath, String?) async -> RemoteProbeOutcome,
        now: Date = Date()
    ) {
        guard !panes.isEmpty else { return }
        var specByDest: [String: ProjectPath] = [:]
        var panesByDest: [String: [Pane]] = [:]
        var boundaryDests: Set<String> = []
        for pane in panes {
            guard let spec = ProjectPath.remote(from: pane.projectPath),
                  case let .remote(user, host, _) = spec
            else { continue }
            let dest = RemoteSpawn.destination(user: user, host: host)
            if seenPaneIDs.insert(pane.id).inserted {
                authRefusedDests.remove(dest)
            }
            specByDest[dest] = spec
            panesByDest[dest, default: []].append(pane)
            if pane.remoteProbePending { boundaryDests.insert(dest) }
        }
        for (dest, spec) in specByDest {
            guard !authRefusedDests.contains(dest) else { continue }
            guard !inflight.contains(dest) else { continue }
            if !boundaryDests.contains(dest),
               let last = lastProbeAt[dest], now.timeIntervalSince(last) < minInterval { continue }
            inflight.insert(dest)
            lastProbeAt[dest] = now
            let targets = panesByDest[dest] ?? []
            // This probe answers every pending boundary request on the host.
            for pane in targets {
                pane.consumeRemoteProbeRequest()
            }
            // zmxPath is a host property — all panes on this dest share it.
            let zmxPath = targets.first?.remoteZmxPath
            Task {
                let outcome = await probe(spec, zmxPath)
                finish(dest: dest, outcome: outcome, panes: targets)
            }
        }
    }

    private func finish(dest: String, outcome: RemoteProbeOutcome, panes: [Pane]) {
        inflight.remove(dest)
        switch outcome {
        case .unreachable:
            // Unreachable/timeout: names freeze at last-known and the next
            // tick retries. Logged once per failure, never surfaced — a
            // flaky link must not nag.
            logger.info("Remote foreground probe failed for \(dest, privacy: .public)")
        case .authRefused:
            // The host denied our BatchMode auth — further probes can only
            // repeat the refusal (or re-raise a biometric key's dialog, the
            // #272 nag), so the destination is suspended until a new pane
            // connects to it. Tier-1 OSC titles keep working; busy-close
            // falls back to the conservative surface reading.
            logger.warning("""
            Remote foreground probe auth refused for \(dest, privacy: .public) — \
            suspending probes for this host (interactive-only key? consider \
            ssh ControlMaster so probes reuse the pane's connection)
            """)
            authRefusedDests.insert(dest)
        case let .success(map):
            for pane in panes {
                if let foreground = map[pane.sessionName] {
                    pane.applyRemoteForeground(foreground)
                } else {
                    // A successful listing with no entry for this session: the
                    // probe raced the session's async registration on the host
                    // (ssh handshake + zmx startup take seconds). A never-named
                    // pane re-arms its request, bounded, so the retry rides the
                    // next poll tick even after its project leaves the frontmost
                    // slot — otherwise the consumed request would strand it nil,
                    // and every close would take the conservative busy fallback.
                    pane.noteRemoteProbeMiss()
                }
            }
        }
    }

    /// Parse `session<TAB>comm<TAB>idleflag<TAB>args` probe lines into a
    /// name → foreground map. The idle flag is the HOST's own verdict
    /// (`1` = the session leader's process group owns the tty, i.e. the
    /// shell sits at its prompt; `0` = some other group holds the
    /// foreground) — absent or unparseable, it maps to nil and the sampling
    /// site falls back to the local-database heuristic. The args field is
    /// optional (a `ps` that reported nothing) and may itself contain tabs
    /// — it's the unsplit remainder of the line, which is why the
    /// fixed-width flag sits before it. Two-field lines (degraded probes)
    /// still parse as name-only. Pure.
    nonisolated static func parseProbeOutput(_ stdout: String) -> [String: RemoteForeground] {
        var map: [String: RemoteForeground] = [:]
        for line in stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let comm = parts[1].trimmingCharacters(in: .whitespaces)
            guard name.hasPrefix("macterm-"), !comm.isEmpty else { continue }
            let flag = parts.count >= 3 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
            let isIdle: Bool? = switch flag {
            case "1": true
            case "0": false
            default: nil
            }
            let args = parts.count > 3 ? parts[3].trimmingCharacters(in: .whitespaces) : ""
            map[name] = RemoteForeground(comm: comm, isIdle: isIdle, command: args.isEmpty ? nil : args)
        }
        return map
    }
}
