import AppKit
@testable import Macterm
import Testing

/// The pinch that zooms a pane: one trigger when the total passes the
/// threshold, then nothing until the gesture ends.
struct PinchZoomGestureTests {
    @Test
    func under_the_threshold_nothing_fires() {
        var pinch = PinchZoomGesture()
        #expect(pinch.track(phase: .began, magnification: 0.05) == nil)
        #expect(pinch.track(phase: .changed, magnification: 0.05) == nil)
        #expect(pinch.track(phase: .ended, magnification: 0) == nil)
    }

    @Test
    func the_event_that_passes_the_threshold_fires_once() {
        var pinch = PinchZoomGesture()
        #expect(pinch.track(phase: .began, magnification: 0.1) == nil)
        #expect(pinch.track(phase: .changed, magnification: 0.1) == .outward)
        // The same gesture goes on, also back the other way: no second fire.
        #expect(pinch.track(phase: .changed, magnification: 0.3) == nil)
        #expect(pinch.track(phase: .changed, magnification: -0.8) == nil)
        #expect(pinch.track(phase: .ended, magnification: 0) == nil)
    }

    @Test
    func a_pinch_in_fires_inward() {
        var pinch = PinchZoomGesture()
        #expect(pinch.track(phase: .began, magnification: -0.1) == nil)
        #expect(pinch.track(phase: .changed, magnification: -0.1) == .inward)
    }

    @Test
    func a_new_gesture_can_fire_again() {
        var pinch = PinchZoomGesture()
        _ = pinch.track(phase: .began, magnification: 0.2)
        #expect(pinch.track(phase: .ended, magnification: 0) == nil)
        #expect(pinch.track(phase: .began, magnification: -0.2) == .inward)
    }

    @Test
    func a_cancelled_gesture_resets_the_total() {
        var pinch = PinchZoomGesture()
        #expect(pinch.track(phase: .began, magnification: 0.1) == nil)
        #expect(pinch.track(phase: .cancelled, magnification: 0) == nil)
        #expect(pinch.track(phase: .began, magnification: 0.1) == nil)
    }

    @Test
    func a_pinch_out_zooms_only_an_unzoomed_pane_of_a_split() {
        #expect(PinchZoomGesture.togglesZoom(.outward, isZoomed: false, isSplit: true))
        #expect(!PinchZoomGesture.togglesZoom(.outward, isZoomed: false, isSplit: false))
        #expect(!PinchZoomGesture.togglesZoom(.outward, isZoomed: true, isSplit: false))
    }

    @Test
    func a_pinch_in_unzooms_only_a_zoomed_pane() {
        #expect(PinchZoomGesture.togglesZoom(.inward, isZoomed: true, isSplit: false))
        #expect(!PinchZoomGesture.togglesZoom(.inward, isZoomed: false, isSplit: true))
        #expect(!PinchZoomGesture.togglesZoom(.inward, isZoomed: false, isSplit: false))
    }
}
