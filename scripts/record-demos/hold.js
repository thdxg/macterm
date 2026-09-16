// Hold a modifier down, tap a key under it, then let go.
//
// System Events' `keystroke … using {shift down}` presses and releases the
// modifier with the key, which is no use to the tab switcher: its overlay
// lives exactly as long as the modifier is held and commits on the
// flags-changed event when it drops (AppState.commitTabCycle). So the events
// are posted at CGEvent level instead, from osascript — a process that
// already holds the Accessibility grant these need.
//
//   osascript -l JavaScript hold.js <modKeycode> <flagMask> <tapKeycode> \
//                                   <taps> <gapSeconds> <holdAfterSeconds>
//
// e.g. shift (56, mask 0x20000) + tab (48), three taps:
//   osascript -l JavaScript hold.js 56 131072 48 3 0.55 1.1
ObjC.import("CoreGraphics");
ObjC.import("Foundation");

function sleep(seconds) {
  $.NSThread.sleepForTimeInterval(seconds);
}

function run(argv) {
  const mod = parseInt(argv[0], 10);
  const mask = parseInt(argv[1], 10);
  const key = parseInt(argv[2], 10);
  const taps = parseInt(argv[3], 10);
  const gap = parseFloat(argv[4]);
  const hold = parseFloat(argv[5]);

  // A source in HID state makes the posted events look like a real keyboard's,
  // which is what the app's local monitor is watching.
  const src = $.CGEventSourceCreate(1);
  const post = (code, isDown, flags) => {
    const e = $.CGEventCreateKeyboardEvent(src, code, isDown);
    if (flags) $.CGEventSetFlags(e, flags);
    $.CGEventPost(0, e);
  };

  post(mod, true, mask);            // modifier down — the overlay opens
  sleep(0.35);
  for (let i = 0; i < taps; i++) {
    post(key, true, mask);          // each tap walks the cycle one card
    post(key, false, mask);
    sleep(gap);
  }
  sleep(hold);                      // let the live previews be seen
  post(mod, false, 0);              // release — this is what commits
  return "ok";
}
