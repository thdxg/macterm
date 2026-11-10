import Foundation

/// One observation of what holds a pane's foreground — the single value the
/// naming and busyness policies read, identical for local and remote panes.
///
/// A sample carries its provenance (local process table or the host's
/// report), so a policy never has to guess where a name came from.
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
        /// A report the host's session pushed through the pane's own connection
        /// (`ZmxForegroundEvents`): current at the moment it arrived, in the
        /// order of the output, and it costs no connection of its own.
        case remoteEvent
    }

    /// Foreground comm basename (normalized), or nil when the origin had
    /// nothing to report. Distinct from "no sample was ever taken", which is
    /// `Pane.foregroundSample == nil`.
    var name: String?

    /// Whether `name` is a shell sitting at its prompt-owner position, judged
    /// by the origin (locally: /etc/shells + login shell; remote: the host's
    /// own verdicts, from its process groups and its /etc/shells, with the
    /// local database only as a fallback — see `Pane.applyRemoteForeground`).
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
    /// removal, the CLI's `busy` error, and the quit dialog rows.
    ///
    /// Local panes trust libghostty's own signal (`surfaceBusy`,
    /// `ghostty_surface_needs_confirm_quit`). A remote pane can't: its local
    /// process is the ssh client, a perpetually "running program", so the
    /// verdict derives from the remote-side signals instead — the OSC
    /// 133/heartbeat execution state (catches a command mid-output), else
    /// the host's latest report (an idle shell is not worth a dialog;
    /// anything else is). A pane with no report (a host with no server, or
    /// before the first report) falls back to the surface's reading, which
    /// for the ssh client is always busy: never silently kill an unknown
    /// foreground.
    static func needsConfirmClose(
        sample: ForegroundSample?,
        executionState: TerminalExecutionState,
        isRemote: Bool,
        hasSurface: Bool,
        surfaceBusy: @autoclosure () -> Bool
    ) -> Bool {
        guard hasSurface else { return false }
        guard isRemote else { return surfaceBusy() }
        return remoteNeedsConfirmClose(sample: sample, executionState: executionState) ?? surfaceBusy()
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
