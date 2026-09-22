// Scroll like a trackpad: precise pixel deltas with gesture phases.
//
// Demo 7 shows smooth scrolling through scrollback, and only a precision
// device engages it — libghostty scrolls by whole rows for anything else, and
// a page-up keybind jumps rows too. So the driver posts CGEvent scroll-wheel
// events in pixel units, with the began/changed/ended phases a real gesture
// carries, at a point inside the pane. The cursor itself stays parked; the
// event carries its own location. Posted from osascript for the same reason
// hold.js is: that process holds the Accessibility grant.
//
//   osascript -l JavaScript scroll.js <x> <y> <pixels> <steps> <seconds>
//
// Positive pixels scroll toward older content (the finger moving down on a
// natural-scrolling trackpad); negative scrolls back toward the prompt.
// e.g. 900 points over 0.9 s, easing out:
//   osascript -l JavaScript scroll.js 960 620 900 36 0.9
ObjC.import("CoreGraphics");
ObjC.import("Foundation");

const kCGScrollEventUnitPixel = 0;
const kCGScrollWheelEventScrollPhase = 99;
const kCGScrollWheelEventMomentumPhase = 123;
const kCGScrollPhaseBegan = 1;
const kCGScrollPhaseChanged = 2;
const kCGScrollPhaseEnded = 4;
const kCGHIDEventTap = 0;

function sleep(seconds) {
  $.NSThread.sleepForTimeInterval(seconds);
}

function run(argv) {
  const x = parseFloat(argv[0]);
  const y = parseFloat(argv[1]);
  const total = parseFloat(argv[2]);
  const steps = Math.max(1, parseInt(argv[3], 10));
  const seconds = parseFloat(argv[4]);
  const src = $.CGEventSourceCreate(1);
  const where = $.CGPointMake(x, y);

  const post = (delta, phase) => {
    const ev = $.CGEventCreateScrollWheelEvent(src, kCGScrollEventUnitPixel, 1, delta);
    $.CGEventSetIntegerValueField(ev, kCGScrollWheelEventScrollPhase, phase);
    $.CGEventSetIntegerValueField(ev, kCGScrollWheelEventMomentumPhase, 0);
    $.CGEventSetLocation(ev, where);
    $.CGEventPost(kCGHIDEventTap, ev);
  };

  // Ease out: big deltas first, tapering, so it reads as a flick that settles
  // rather than a conveyor belt. Weights are sin over a quarter turn; their
  // sum is what the total is split over, so every run lands exactly on total.
  const weights = [];
  let sum = 0;
  for (let i = 0; i < steps; i++) {
    const w = Math.cos((i / steps) * (Math.PI / 2));
    weights.push(w);
    sum += w;
  }

  post(0, kCGScrollPhaseBegan);
  let sent = 0;
  for (let i = 0; i < steps; i++) {
    const target = Math.round((total * weights.slice(0, i + 1).reduce((a, b) => a + b, 0)) / sum);
    const delta = target - sent;
    sent = target;
    post(delta, kCGScrollPhaseChanged);
    sleep(seconds / steps);
  }
  post(0, kCGScrollPhaseEnded);
  return "ok";
}
