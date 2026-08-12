import Foundation
@testable import Macterm
import Testing

struct ForegroundSampleTests {
    private func sample(
        name: String?,
        isIdleShell: Bool = false,
        origin: ForegroundSample.Origin = .remoteProbe
    ) -> ForegroundSample {
        ForegroundSample(name: name, isIdleShell: isIdleShell, origin: origin, sampledAt: Date())
    }

    // MARK: - needsConfirmClose (the full verdict)

    @Test
    func no_surface_is_never_busy() {
        #expect(!ForegroundPolicy.needsConfirmClose(
            sample: nil, executionState: .running, isRemote: true,
            hasSurface: false, surfaceBusy: true
        ))
    }

    @Test
    func local_panes_trust_the_surface_signal_regardless_of_sample() {
        // libghostty's own verdict is authoritative locally — the sample is
        // naming state, never a busy override.
        #expect(ForegroundPolicy.needsConfirmClose(
            sample: sample(name: "zsh", isIdleShell: true, origin: .processTable(pid: 1)),
            executionState: .idle, isRemote: false,
            hasSurface: true, surfaceBusy: true
        ))
        #expect(!ForegroundPolicy.needsConfirmClose(
            sample: sample(name: "btop", origin: .processTable(pid: 1)),
            executionState: .idle, isRemote: false,
            hasSurface: true, surfaceBusy: false
        ))
    }

    @Test
    func remote_running_execution_state_is_busy_before_any_sample() {
        #expect(ForegroundPolicy.needsConfirmClose(
            sample: nil, executionState: .running, isRemote: true,
            hasSurface: true, surfaceBusy: false
        ))
    }

    @Test
    func remote_idle_shell_sample_is_not_busy() {
        #expect(!ForegroundPolicy.needsConfirmClose(
            sample: sample(name: "bash", isIdleShell: true),
            executionState: .idle, isRemote: true,
            hasSurface: true, surfaceBusy: true
        ))
    }

    @Test
    func remote_program_sample_is_busy() {
        #expect(ForegroundPolicy.needsConfirmClose(
            sample: sample(name: "btop", isIdleShell: false),
            executionState: .idle, isRemote: true,
            hasSurface: true, surfaceBusy: false
        ))
    }

    @Test
    func remote_without_any_sample_falls_back_to_the_surface() {
        // Never silently kill an unknown foreground: an unreachable host or
        // the registration window leaves no observation, and the
        // conservative ssh-is-busy surface reading stands in.
        #expect(ForegroundPolicy.needsConfirmClose(
            sample: nil, executionState: .idle, isRemote: true,
            hasSurface: true, surfaceBusy: true
        ))
        #expect(!ForegroundPolicy.needsConfirmClose(
            sample: nil, executionState: .idle, isRemote: true,
            hasSurface: true, surfaceBusy: false
        ))
    }

    @Test
    func remote_verdict_reads_the_sampled_shellness_not_the_name() {
        // Shell-ness is judged at sampling time by the origin. The policy
        // must not re-derive it from the name — that re-derivation is
        // exactly the local-/etc/shells-vs-remote-host bug: a remote-only
        // login shell isn't in the local database, and only the recorded
        // verdict can say it was idle.
        #expect(!ForegroundPolicy.needsConfirmClose(
            sample: sample(name: "exotic-shell", isIdleShell: true),
            executionState: .idle, isRemote: true,
            hasSurface: true, surfaceBusy: true
        ))
    }

    // MARK: - remoteNeedsConfirmClose (the nil-able split)

    @Test
    func remote_verdict_is_nil_only_before_any_sample() {
        #expect(ForegroundPolicy.remoteNeedsConfirmClose(
            sample: nil, executionState: .idle
        ) == nil)
        #expect(ForegroundPolicy.remoteNeedsConfirmClose(
            sample: sample(name: "bash", isIdleShell: true), executionState: .idle
        ) == false)
        #expect(ForegroundPolicy.remoteNeedsConfirmClose(
            sample: sample(name: "hx"), executionState: .idle
        ) == true)
        #expect(ForegroundPolicy.remoteNeedsConfirmClose(
            sample: nil, executionState: .running
        ) == true)
    }
}
