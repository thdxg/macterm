// Macterm — Smooth cursor (Settings → Experimental → Smooth cursor).
//
// Macterm adds this shader through `custom-shader` together with
// `cursor-opacity = 0`: ghostty's own cursor is hidden while the pane is
// focused and this shader *is* the cursor, drawn at an eased position
// between where it was and where it is. Unfocused panes keep ghostty's
// hollow cursor (cursor-opacity applies only while focused), so this draws
// nothing there (iFocus == 0).
//
// Text under a block cursor: even with the cursor invisible, ghostty still
// paints the glyph in the cursor's cell in the cursor-text color (default:
// the background color). It is recovered from iChannel0 by that color and
// kept on top of the drawn block — the native cursor look. A cell whose own
// background is painted in exactly that color hides the cursor; rare, since
// Macterm leaves default-background cells transparent.

// --- Tuning ---
const float DURATION = 0.14;        // seconds for one glide
const float AA = 1.0;               // edge antialiasing in pixels
const float TEXT_TOLERANCE = 0.05;  // framebuffer-RGB distance still read as cursor-text

// --- Output encoding (set by Macterm from the user's ghostty config) ---
// A custom shader writes straight into ghostty's framebuffer, which is
// always Display P3 and holds gamma-encoded values under `alpha-blending =
// native` (the macOS default) or linear ones under `linear` /
// `linear-corrected`. Uniform colors arrive as the raw sRGB-encoded numbers
// from the config; with `window-colorspace = display-p3` ghostty treats them
// as P3 already, otherwise it converts. This mirrors `load_color` in
// ghostty's shaders.metal so the drawn cursor is the color the native one
// would be. Macterm prepends the two defines when it installs this file
// (ExperimentShaders); the fallbacks below are macOS's defaults.
#ifndef MACTERM_LINEAR_BLENDING
#define MACTERM_LINEAR_BLENDING 0
#endif
#ifndef MACTERM_DISPLAY_P3
#define MACTERM_DISPLAY_P3 0
#endif

vec3 mactermLinearize(vec3 c) {
    return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, step(c, vec3(0.04045)));
}

vec3 mactermUnlinearize(vec3 c) {
    return mix(pow(c, vec3(1.0 / 2.4)) * 1.055 - 0.055, c * 12.92, step(c, vec3(0.0031308)));
}

// Linear sRGB -> linear Display P3, via D50 XYZ (ghostty's matrices).
vec3 mactermSRGBToDisplayP3(vec3 c) {
    mat3 srgbToXYZ = transpose(mat3(
        0.4360747, 0.3850649, 0.1430804,
        0.2225045, 0.7168786, 0.0606169,
        0.0139322, 0.0971045, 0.7141733));
    mat3 xyzToP3 = transpose(mat3(
        2.40414768, -0.99010704, -0.39759019,
        -0.84239098, 1.79905954, 0.01597023,
        0.04838763, -0.09752546, 1.27393636));
    return xyzToP3 * (srgbToXYZ * c);
}

// A config color (sRGB-encoded numbers) as the framebuffer stores it.
vec3 mactermEncode(vec3 c) {
#if MACTERM_DISPLAY_P3 && !MACTERM_LINEAR_BLENDING
    return c;
#else
    c = mactermLinearize(c);
#if !MACTERM_DISPLAY_P3
    c = mactermSRGBToDisplayP3(c);
#endif
#if !MACTERM_LINEAR_BLENDING
    c = mactermUnlinearize(c);
#endif
    return c;
#endif
}

// EaseOutCubic.
float ease(float x) {
    return 1.0 - pow(1.0 - x, 3.0);
}

float sdfRect(vec2 p, vec2 center, vec2 halfSize) {
    vec2 d = abs(p - center) - halfSize;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// iCurrentCursor / iPreviousCursor are (left, top edge, width, height) in
// pixels, y up: the rect spans [y - h, y].
vec2 rectCenter(vec4 r) {
    return vec2(r.x + r.z * 0.5, r.y - r.w * 0.5);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 tex = texture(iChannel0, fragCoord / iResolution.xy);
    fragColor = tex;

    if (iCursorVisible == 0 || iFocus == 0) return;
    if (iCurrentCursorStyle == CURSORSTYLE_BLOCK_HOLLOW ||
        iCurrentCursorStyle == CURSORSTYLE_LOCK) return;

    vec4 cur = iCurrentCursor;
    vec4 prev = iPreviousCursor;
    // An all-zero previous cursor is the first frame after launch; don't
    // glide in from the window corner.
    if (dot(prev.zw, prev.zw) == 0.0) prev = cur;

    float t = clamp((iTime - iTimeCursorChange) / DURATION, 0.0, 1.0);
    float e = ease(t);

    vec2 center = mix(rectCenter(prev), rectCenter(cur), e);
    vec2 halfSize = mix(prev.zw, cur.zw, e) * 0.5;
    vec4 cursor = vec4(mactermEncode(mix(iPreviousCursorColor.rgb, iCurrentCursorColor.rgb, e)), 1.0);

    float coverage = 1.0 - smoothstep(0.0, AA, sdfRect(fragCoord, center, halfSize));
    if (coverage <= 0.0) return;

    // The destination cell's glyph, painted by ghostty in cursor-text (see
    // header): keep it on top of the block.
    vec3 textColor = dot(iCursorText, iCursorText) > 0.0 ? iCursorText : iBackgroundColor;
    vec3 textEncoded = mactermEncode(textColor);
    float inTarget = 1.0 - step(0.0, sdfRect(fragCoord, rectCenter(cur), cur.zw * 0.5));
    vec3 texel = tex.rgb / max(tex.a, 1e-4);
    float isText = 1.0 - smoothstep(TEXT_TOLERANCE, TEXT_TOLERANCE * 2.0, distance(texel, textEncoded));
    float text = tex.a * isText * inTarget;
    vec4 cursorPixel = mix(cursor, vec4(textEncoded, 1.0), text);

    fragColor = mix(tex, cursorPixel, coverage);
}
