// Macterm — Cursor trail (Settings → Experimental → Cursor trail).
//
// A translucent streak in the cursor color from where the cursor was to
// where it is, whose tail catches up with its head over DURATION. Macterm
// lists this shader before cursor_glide.glsl, so with both on the streak is
// drawn behind the gliding cursor, and the timing matches so the streak's
// head tracks the glide rather than the cell the cursor will land in.

// --- Tuning ---
const float DURATION = 0.14;  // seconds; keep equal to cursor_glide.glsl
const float TAIL_LAG = 0.5;   // fraction of the move the tail waits before following
const float OPACITY = 0.6;    // peak streak opacity
const float AA = 1.0;         // edge antialiasing in pixels

// Uniform colors arrive as sRGB; iChannel0 and the output are linear.
vec3 sRGBToLinear(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

// EaseOutCubic.
float ease(float x) {
    return 1.0 - pow(1.0 - x, 3.0);
}

// iCurrentCursor / iPreviousCursor are (left, top edge, width, height) in
// pixels, y up: the rect spans [y - h, y].
vec2 rectCenter(vec4 r) {
    return vec2(r.x + r.z * 0.5, r.y - r.w * 0.5);
}

// Distance to an axis-aligned box of `halfSize` swept along the segment
// a→b. The box slides rather than rotates, so a diagonal move leaves a
// slanted streak with square ends — the shape a sliding cursor would paint.
float sdfSweptRect(vec2 p, vec2 a, vec2 b, vec2 halfSize) {
    vec2 ab = b - a;
    float h = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    vec2 d = abs(p - (a + ab * h)) - halfSize;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 tex = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = tex;

    if (iCursorVisible == 0 || iFocus == 0) return;

    vec4 cur = iCurrentCursor;
    vec4 prev = iPreviousCursor;
    // No previous cursor yet (first frame after launch): nothing to trail.
    if (dot(prev.zw, prev.zw) == 0.0) return;

    float t = clamp((iTime - iTimeCursorChange) / DURATION, 0.0, 1.0);
    if (t >= 1.0) return;

    vec2 from = rectCenter(prev);
    vec2 to = rectCenter(cur);
    // Typing moves the cursor one cell at a time; a streak there is noise.
    if (distance(from, to) < cur.w * 1.5) return;

    float head = ease(t);
    float tail = ease(clamp((t - TAIL_LAG) / (1.0 - TAIL_LAG), 0.0, 1.0));
    vec2 a = mix(from, to, tail);
    vec2 b = mix(from, to, head);
    vec2 halfSize = mix(prev.zw, cur.zw, head) * 0.5;

    float coverage = 1.0 - smoothstep(0.0, AA, sdfSweptRect(fragCoord, a, b, halfSize));
    float alpha = coverage * OPACITY * (1.0 - t);
    if (alpha <= 0.0) return;

    vec4 streak = vec4(sRGBToLinear(iCurrentCursorColor.rgb), 1.0);
    // Premultiplied "over".
    fragColor = tex * (1.0 - alpha) + streak * alpha;
}
