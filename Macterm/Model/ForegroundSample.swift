import Foundation

/// One observation of what holds a pane's foreground — the single value the
/// naming and busyness policies read, identical for local and remote panes.
///
/// Before this type, the two pipelines published bare `String?` names with
/// different freshness semantics (local: recomputed every poll tick; remote:
/// pushed by an ssh probe minutes-stale at worst) and consumers could not
/// tell them apart — the busy-close guard had to reconstruct "was there ever
/// a probe result?" from name nil-ness. A sample carries its provenance
/// explicitly instead.
///
/// Shell-ness is judged AT SAMPLING TIME by the origin that produced the
/// observation, not at read time by the consumer: a policy reading
/// `isIdleShell` doesn't need to know which host's shell database applies (the
/// local /etc/shells is wrong for a remote comm — a remote-only login shell
/// would read as a running program forever).
struct ForegroundSample: Equatable {
    enum Origin: Equatable {
        /// The local process table (`ProcessInspector` syscalls); `pid` is
        /// the resolved foreground pid the observation came from (nil when
        /// the pane had no live surface/pid to inspect).
        case processTable(pid: pid_t?)
        /// The per-host ssh probe (`RemoteForegroundResolver`).
        case remoteProbe
    }

    /// Foreground comm basename (normalized), or nil when the origin had
    /// nothing to report. Distinct from "no sample was ever taken", which is
    /// `Pane.foregroundSample == nil`.
    var name: String?

    /// Whether `name` is a shell sitting at its prompt-owner position, judged
    /// by the origin (locally: /etc/shells + login shell; remote: currently
    /// the same local database — moving host-side is planned, and recording
    /// the verdict here is what makes that swap a one-file change).
    var isIdleShell: Bool

    var origin: Origin

    /// When this observation was made (the sample is republished only when
    /// the observation changes, so this is "first seen", not "last
    /// confirmed" — republishing every tick would re-render the sidebar at
    /// poll cadence for no visible change).
    var sampledAt: Date
}

/// The pure policies every consumer of a pane's foreground state shares.
/// Free functions over (sample, executionState, …) so they are trivially
/// characterization-testable and cannot fork per call site.
enum ForegroundPolicy {
    /// Whether closing must be confirmed because a foreground program is
    /// running — the single verdict behind pane/tab close, project
    /// unload/remove, the CLI's `busy` error, and the quit dialog rows.
    ///
    /// Local panes trust libghostty's own signal (`surfaceBusy`,
    /// `ghostty_surface_needs_confirm_quit`). A remote pane can't: its local
    /// process is the ssh client, a perpetually "running program", so the
    /// verdict derives from the remote-side signals instead — the OSC
    /// 133/heartbeat execution state (catches a command mid-output before
    /// any probe lands), else the probe sample (an idle shell is not worth a
    /// dialog; anything else is). Only when NO probe observation has ever
    /// landed (unreachable host, BatchMode auth failure, the registration
    /// window) does it fall back to the conservative `surfaceBusy` reading —
    /// never silently killing an unknown foreground.
    ///
    /// `remoteProbingEnabled` = `Preferences.backgroundSSHConnections`. Off,
    /// only the execution state can warn: any probe sample is a frozen relic
    /// from before the toggle flipped, and the conservative fallback would
    /// warn on EVERY close forever (no probe can ever land) — the user chose
    /// "don't warn" over "always warn" when they turned probing off. Local
    /// panes are untouched: their signals cost no ssh connections.
    static func needsConfirmClose(
        sample: ForegroundSample?,
        executionState: TerminalExecutionState,
        isRemote: Bool,
        hasSurface: Bool,
        remoteProbingEnabled: Bool = true,
        surfaceBusy: @autoclosure () -> Bool
    ) -> Bool {
        guard hasSurface else { return false }
        guard isRemote else { return surfaceBusy() }
        if executionState == .running { return true }
        guard remoteProbingEnabled else { return false }
        guard let sample, let name = sample.name, !name.isEmpty else { return surfaceBusy() }
        return !sample.isIdleShell
    }

    /// The remote-side busy verdict alone, nil when no sample has ever
    /// landed. Split out so unit tests can exercise the decision without a
    /// live NSView (the surface fallback needs one).
    static func remoteNeedsConfirmClose(
        sample: ForegroundSample?,
        executionState: TerminalExecutionState
    ) -> Bool? {
        if executionState == .running { return true }
        guard let sample, let name = sample.name, !name.isEmpty else { return nil }
        return !sample.isIdleShell
    }
}
