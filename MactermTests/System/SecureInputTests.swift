import Foundation
@testable import Macterm
import Testing

/// Exercises the enable/disable balancing logic with injected system hooks —
/// the real Carbon calls must never fire under the test runner (they'd flip
/// actual secure input for the hosting app).
@MainActor
struct SecureInputTests {
    /// Records hook calls; a class so closures share one instance.
    private final class Recorder {
        var enables = 0
        var disables = 0
    }

    private func makeInput(active: Bool = true, enableResult: OSStatus = noErr) -> (SecureInput, Recorder) {
        let recorder = Recorder()
        let input = SecureInput()
        input.enableHook = {
            recorder.enables += 1
            return enableResult
        }
        input.disableHook = {
            recorder.disables += 1
            return noErr
        }
        input.isAppActive = { active }
        return (input, recorder)
    }

    @Test
    func globalToggle_flipsSystemState() {
        let (input, recorder) = makeInput()
        input.setGlobal(true)
        #expect(input.enabled)
        #expect(recorder.enables == 1)
        input.setGlobal(false)
        #expect(!input.enabled)
        #expect(recorder.disables == 1)
    }

    @Test
    func scopedObject_enablesOnlyWhileFocused() {
        let (input, recorder) = makeInput()
        // Keep the anchor object alive: an ObjectIdentifier of a deallocated
        // object can collide with the next allocation at the same address.
        let anchor = NSObject()
        let object = ObjectIdentifier(anchor)

        input.setScoped(object, focused: false)
        #expect(!input.enabled)
        #expect(recorder.enables == 0)

        input.setScoped(object, focused: true)
        #expect(input.enabled)

        input.setScoped(object, focused: false)
        #expect(!input.enabled)
        #expect(recorder.disables == 1)
    }

    @Test
    func removeScoped_releasesTheHold() {
        let (input, recorder) = makeInput()
        let anchor = NSObject()
        let object = ObjectIdentifier(anchor)
        input.setScoped(object, focused: true)
        #expect(input.enabled)
        input.removeScoped(object)
        #expect(!input.enabled)
        #expect(recorder.enables == 1)
        #expect(recorder.disables == 1)
    }

    @Test
    func overlappingHolds_stayBalanced() {
        // The OS call must flip exactly once per edge no matter how many
        // inputs want it — an unbalanced EnableSecureEventInput would wedge
        // system-wide secure input on.
        let (input, recorder) = makeInput()
        let anchorA = NSObject(), anchorB = NSObject()
        let a = ObjectIdentifier(anchorA)
        let b = ObjectIdentifier(anchorB)

        input.setGlobal(true)
        input.setScoped(a, focused: true)
        input.setScoped(b, focused: true)
        #expect(recorder.enables == 1)

        input.setGlobal(false)
        input.removeScoped(a)
        #expect(input.enabled) // b still holds it
        #expect(recorder.disables == 0)

        input.removeScoped(b)
        #expect(!input.enabled)
        #expect(recorder.disables == 1)
    }

    @Test
    func inactiveApp_neverTouchesSystemState() {
        // Secure input is global: while another app is frontmost we must not
        // grab it. The activation observer reacquires later.
        let (input, recorder) = makeInput(active: false)
        input.setGlobal(true)
        #expect(!input.enabled)
        #expect(recorder.enables == 0)
    }

    @Test
    func failedEnable_leavesStateOff() {
        let (input, recorder) = makeInput(enableResult: OSStatus(-1))
        input.setGlobal(true)
        #expect(!input.enabled)
        #expect(recorder.enables == 1)
        // No phantom outstanding enable to balance on the way down.
        input.setGlobal(false)
        #expect(recorder.disables == 0)
    }
}
