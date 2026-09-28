// Move, click and drag the pointer like a hand would — for the demos that
// record the cursor (the Dock drop, a desktop widget dragged into place).
//
// Every other demo is keyboard-driven with the cursor hidden; these two are
// about a mouse gesture, so the pointer is in frame and has to travel the
// way a person moves it: eased in and out, on a slight arc, never a jump.
// The events are posted at CGEvent level in HID state, as hold.js and
// scroll.js do, from osascript — the process holding the Accessibility grant.
//
//   osascript -l JavaScript mouse.js move  <x> <y> <seconds>
//   osascript -l JavaScript mouse.js click <x> <y> [right]
//   osascript -l JavaScript mouse.js drag  <x1> <y1> <x2> <y2> <seconds>
//   osascript -l JavaScript mouse.js dockdrop <x1> <y1> <app name> <seconds>
//
// `move` starts wherever the pointer is. `drag` presses at (x1,y1), travels
// to (x2,y2) and lets go. `dockdrop` presses at (x1,y1), carries the item
// down to the bottom edge so an auto-hidden Dock slides up, finds the app's
// tile there (its position is only known once the Dock is showing), and
// lets go on it.
ObjC.import("CoreGraphics");
ObjC.import("Foundation");
ObjC.import("AppKit");

const kCGHIDEventTap = 0;
const kCGEventLeftMouseDown = 1;
const kCGEventLeftMouseUp = 2;
const kCGEventRightMouseDown = 3;
const kCGEventRightMouseUp = 4;
const kCGEventMouseMoved = 5;
const kCGEventLeftMouseDragged = 6;
const kCGMouseEventClickState = 1;
const FPS = 90;

function sleep(seconds) {
  $.NSThread.sleepForTimeInterval(seconds);
}

const src = $.CGEventSourceCreate(1);

function post(type, x, y, button) {
  const e = $.CGEventCreateMouseEvent(src, type, $.CGPointMake(x, y), button || 0);
  if (type !== kCGEventMouseMoved && type !== kCGEventLeftMouseDragged) {
    $.CGEventSetIntegerValueField(e, kCGMouseEventClickState, 1);
  }
  $.CGEventPost(kCGHIDEventTap, e);
}

function where() {
  const e = $.CGEventCreate(null);
  const p = $.CGEventGetLocation(e);
  return [p.x, p.y];
}

// Smootherstep: zero velocity and acceleration at both ends.
function ease(t) {
  return t * t * t * (t * (t * 6 - 15) + 10);
}

// Travel from a to b over `seconds`, bowing the path a little to one side —
// a straight ruler line is the tell of a synthetic pointer.
function travel(ax, ay, bx, by, seconds, type) {
  const steps = Math.max(2, Math.round(seconds * FPS));
  const dx = bx - ax;
  const dy = by - ay;
  const len = Math.hypot(dx, dy) || 1;
  const bow = Math.min(60, len * 0.08);
  const nx = -dy / len;
  const ny = dx / len;
  for (let i = 1; i <= steps; i++) {
    const t = ease(i / steps);
    const arc = Math.sin(Math.PI * t) * bow;
    post(type, ax + dx * t + nx * arc, ay + dy * t + ny * arc, 0);
    sleep(seconds / steps);
  }
}

function dockTile(appName) {
  const dock = Application("System Events").processes.byName("Dock");
  const items = dock.lists[0].uiElements();
  for (const item of items) {
    let name = null;
    try { name = item.name(); } catch (e) { continue; }
    if (name !== appName) continue;
    const p = item.position();
    const s = item.size();
    return [p[0] + s[0] / 2, p[1] + s[1] / 2];
  }
  return null;
}

function run(argv) {
  const verb = argv[0];
  const n = (i) => parseFloat(argv[i]);

  if (verb === "move") {
    const [x, y] = where();
    travel(x, y, n(1), n(2), n(3), kCGEventMouseMoved);
    return "ok";
  }

  if (verb === "click") {
    const right = argv[3] === "right";
    post(kCGEventMouseMoved, n(1), n(2), 0);
    sleep(0.05);
    post(right ? kCGEventRightMouseDown : kCGEventLeftMouseDown, n(1), n(2), right ? 1 : 0);
    sleep(0.09);
    post(right ? kCGEventRightMouseUp : kCGEventLeftMouseUp, n(1), n(2), right ? 1 : 0);
    return "ok";
  }

  if (verb === "drag") {
    const [x1, y1, x2, y2, secs] = [n(1), n(2), n(3), n(4), n(5)];
    post(kCGEventMouseMoved, x1, y1, 0);
    sleep(0.12);
    post(kCGEventLeftMouseDown, x1, y1, 0);
    sleep(0.18);
    // a few short moves first, past any drag threshold, as a hand starts out
    travel(x1, y1, x1 + 6, y1 + 4, 0.12, kCGEventLeftMouseDragged);
    travel(x1 + 6, y1 + 4, x2, y2, secs, kCGEventLeftMouseDragged);
    sleep(0.25);
    post(kCGEventLeftMouseUp, x2, y2, 0);
    return "ok";
  }

  if (verb === "dockdrop") {
    const [x1, y1, secs] = [n(1), n(2), n(4)];
    const appName = argv[3];
    const screen = $.NSScreen.mainScreen.frame.size;
    post(kCGEventMouseMoved, x1, y1, 0);
    sleep(0.12);
    post(kCGEventLeftMouseDown, x1, y1, 0);
    sleep(0.2);
    travel(x1, y1, x1 + 8, y1 + 6, 0.15, kCGEventLeftMouseDragged);
    // Aim for where the tile will be. Until the Dock shows, its tiles sit
    // below the screen but keep their x, so that much is known already.
    const hidden = dockTile(appName);
    const aimX = hidden ? hidden[0] : screen.width / 2;
    const edge = screen.height - 2;
    travel(x1 + 8, y1 + 6, aimX, edge, secs, kCGEventLeftMouseDragged);
    // wiggle on the edge until the Dock has slid up and the tile is on screen
    let tile = null;
    for (let i = 0; i < 30; i++) {
      post(kCGEventLeftMouseDragged, aimX + (i % 2 ? 1 : -1), edge, 0);
      sleep(0.05);
      tile = dockTile(appName);
      if (tile && tile[1] < screen.height - 8) break;
    }
    if (!tile) tile = [aimX, screen.height - 30];
    // the Dock magnifies under the pointer, which moves the tiles; settle on
    // the tile, then re-read it once the magnification has caught up
    travel(aimX, edge, tile[0], tile[1], 0.35, kCGEventLeftMouseDragged);
    sleep(0.2);
    const settled = dockTile(appName) || tile;
    travel(tile[0], tile[1], settled[0], settled[1], 0.12, kCGEventLeftMouseDragged);
    sleep(0.55);                      // the tile highlights: it takes folders
    post(kCGEventLeftMouseUp, settled[0], settled[1], 0);
    return "ok";
  }

  throw new Error("usage: mouse.js move|click|drag|dockdrop …");
}
