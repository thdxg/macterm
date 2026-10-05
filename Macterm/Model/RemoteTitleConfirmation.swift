import Foundation

/// Whether a remote pane's OSC 0/2 title came from a program, decided by a
/// probe sent AFTER the title arrived.
///
/// A remote pane has no local pid to pin a title to, so a title that arrives
/// while a command runs is the program's (`Pane.receiveRemoteReportedTitle`).
/// Outside a run, the only witness is the foreground probe, and its sample
/// can be a round trip or more out of date. When an agent quits, the shell's
/// prompt title (`~/dev`) arrives while the last sample still says the agent
/// is in front. Trusting that sample adopted the shell's title, and with
/// probes suspended (#272) or Background SSH off it was never cleared (#473).
///
/// So a title from outside a run is held here and shown only once a probe
/// that went out after it reports a program in front. A shell report
/// discards it. The title a run left on screen is kept but marked
/// unconfirmed, and the same probe confirms or clears it, so the tab does
/// not flicker to the process name each time an agent finishes a turn.
///
/// The `revision` counter, not a timestamp, decides what a probe may vouch
/// for. Every hold, demotion and reset advances it, and `Pane` records it as
/// each probe goes out (`noteProbeDispatched`). An answer whose recorded
/// revision is out of date says nothing about the current title, so it is
/// ignored and the next probe decides. `ForegroundSample.sampledAt` cannot
/// do this: it is "first seen" and does not change while the answer stays
/// the same. A wall-clock time taken when the answer arrives would credit a
/// probe sent before the title. This works because the resolver keeps at
/// most one probe in flight per host and records every pane on that host as
/// the probe goes out.
///
/// A value type, owned one per pane, in the `TitleReportThrottle` style.
struct RemoteTitleConfirmation: Equatable {
    /// A title reported outside a run, not shown until a probe confirms it.
    private(set) var pending: String?

    /// The title on screen outlived the run that set it, and a probe has not
    /// yet said whether its program is still in front.
    private(set) var shownUnconfirmed = false

    private var revision: UInt64 = 0
    private var revisionAtDispatch: UInt64?

    /// Something waits on the next probe: the pane should be probed even
    /// from a background project.
    var awaitsProbe: Bool { pending != nil || shownUnconfirmed }

    /// What a probe's answer means for the title.
    enum Verdict: Equatable {
        /// The answer was for a probe sent before the latest change, or
        /// nothing was waiting on it. Leave the title as it is.
        case undecided
        /// A program is in front. Show `title`, or keep the title on screen
        /// when nil.
        case adopt(String?)
        /// The shell is in front. Drop the title.
        case clear
    }

    /// Hold a title reported outside a run. The newest one wins, but the
    /// same title held again changes nothing: a program that re-emits its
    /// idle title on every redraw would otherwise advance the revision each
    /// time, voiding any probe already in flight, and a title re-emitted
    /// more often than a probe round trip (~3s plus the ssh connect) would
    /// never be confirmed and shown.
    mutating func hold(_ title: String) {
        guard title != pending else { return }
        pending = title
        revision &+= 1
    }

    /// The run that set the shown title ended while a program was still in
    /// front. Keep it on screen until a probe confirms it.
    mutating func demoteShown() {
        shownUnconfirmed = true
        revision &+= 1
    }

    /// Forget a held title, but keep any unconfirmed one on screen.
    mutating func dropPending() {
        guard pending != nil else { return }
        pending = nil
        revision &+= 1
    }

    /// Nothing waits any more: a title was set by a run, the prompt came
    /// back, or the probe can no longer answer. Advancing the revision means
    /// a probe already in flight cannot act on the old state.
    mutating func reset() {
        pending = nil
        shownUnconfirmed = false
        revision &+= 1
    }

    /// A probe covering this pane just went out.
    mutating func noteProbeDispatched() {
        revisionAtDispatch = revision
    }

    /// A probe answered. `programInFront` is that probe's sample.
    mutating func resolve(programInFront: Bool) -> Verdict {
        guard awaitsProbe, revisionAtDispatch == revision else { return .undecided }
        let title = pending
        pending = nil
        shownUnconfirmed = false
        revision &+= 1
        return programInFront ? .adopt(title) : .clear
    }
}
