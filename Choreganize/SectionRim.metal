#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// Section rim: the light on a section card's edge. A hairline drawn as a fraction of the
// card's perimeter (the section's progress), a soft halo that falls off outward from the
// edge, and the flourish (a retraced line with a bright head) when the section finishes.
// Everything is drawn OUTSIDE the card: the layer sits behind an opaque List card, so the
// strip that reaches 0.5 pt under the edge only keeps the anti-aliased seam closed.
//
// Used as a SwiftUI `colorEffect` on a rectangle that covers the card rect outset by `reach`
// points on every side (the card's centre is the layer's centre). `position` and `color` are
// implicit and the input colour is ignored (the rim is returned over transparent,
// premultiplied). Custom parameters follow in order:
//   size       the card's size in points
//   radius     the card's corner radius in points
//   reach      how far the layer extends past the card on each side (nothing draws beyond it)
//   rtl        1 in a right-to-left layout (the path starts at the lower LEFT corner and runs
//              mirrored), else 0
//   dark       1 in dark appearance, else 0 (sets the halo tone)
//   scale      display scale (pixels per point), for anti-aliasing
//   baseFill   fraction of the perimeter the resting hairline covers
//   baseA      the resting hairline's opacity
//   lineFill   fraction of the perimeter the flourish line covers (also where the head sits)
//   lineA      the flourish line's opacity
//   headA      the head's opacity
//   haloLevel  halo strength (0.14 at rest at 100 %, 0.40 at the flourish's peak)
//   tint       honey (#FFD978) by day, lavender (#AEB4FF) by night
//
// The path starts at the lower trailing corner (where the bottom-right arc begins on the
// right edge, LTR) and runs along the bottom toward leading, up the leading side, across the
// top and down the trailing side. `SectionRim` (Swift) mirrors the geometry for tests.
//
// The halo emulates the approved playground's two 3 pt strokes blurred by sigma 6 and 18,
// masked to the outside: a half-Gaussian falloff from the edge. Cost: pixels beyond `reach`
// or inside the card return at once; the rest evaluate one atan2 and a few exps.

namespace rim {

constant float kPi = 3.14159265f;

struct Geometry {
    float2 inner;   // half extents of the rectangle the corner arcs' centres lie on
    float radius;
    float arc;      // length of one corner arc
    float lineH;    // length of a horizontal edge between arcs
    float lineV;    // length of a vertical edge between arcs
    float perimeter;
};

inline Geometry makeGeometry(float2 size, float radius) {
    Geometry g;
    float2 halfExtent = size * 0.5;
    g.radius = clamp(radius, 0.0f, min(halfExtent.x, halfExtent.y));
    g.inner = halfExtent - g.radius;
    g.arc = kPi * 0.5f * g.radius;
    g.lineH = 2.0f * g.inner.x;
    g.lineV = 2.0f * g.inner.y;
    g.perimeter = 4.0f * g.arc + 2.0f * g.lineH + 2.0f * g.lineV;
    return g;
}

// Signed distance to the rounded card, q centred on the card.
inline float signedDistance(float2 q, Geometry g) {
    float2 d = abs(q) - g.inner;
    return length(max(d, 0.0f)) + min(max(d.x, d.y), 0.0f) - g.radius;
}

// Distance in points along the path (from 0 at the start) of the boundary point nearest to q.
inline float arcLength(float2 q, Geometry g) {
    bool outX = abs(q.x) > g.inner.x;
    bool outY = abs(q.y) > g.inner.y;
    float2 v = q - clamp(q, -g.inner, g.inner);
    if (outX && outY) {
        float theta = atan2(v.y, v.x);
        if (theta < 0.0f) { theta += 2.0f * kPi; }
        // Quadrant: 0 lower trailing (BR), 1 lower leading, 2 upper leading, 3 upper trailing.
        float k = q.y > 0.0f ? (q.x > 0.0f ? 0.0f : 1.0f) : (q.x < 0.0f ? 2.0f : 3.0f);
        float base = k < 0.5f ? 0.0f
                   : k < 1.5f ? g.arc + g.lineH
                   : k < 2.5f ? 2.0f * g.arc + g.lineH + g.lineV
                              : 3.0f * g.arc + 2.0f * g.lineH + g.lineV;
        return base + g.radius * clamp(theta - k * 0.5f * kPi, 0.0f, 0.5f * kPi);
    }
    if (outY) {
        return q.y > 0.0f ? g.arc + (g.inner.x - q.x)
                          : 3.0f * g.arc + g.lineH + g.lineV + (q.x + g.inner.x);
    }
    if (outX) {
        return q.x > 0.0f ? 4.0f * g.arc + 2.0f * g.lineH + g.lineV + (q.y + g.inner.y)
                          : 2.0f * g.arc + g.lineH + (g.inner.y - q.y);
    }
    return 0.0f;
}

// The boundary point `s` points along the path (inverse of `arcLength`).
inline float2 pointAt(float s, Geometry g) {
    float r = g.radius;
    float2 c = g.inner;
    if (s < g.arc) { float t = s / max(r, 1e-4f); return c + r * float2(cos(t), sin(t)); }
    s -= g.arc;
    if (s < g.lineH) { return float2(c.x - s, c.y + r); }
    s -= g.lineH;
    if (s < g.arc) { float t = 0.5f * kPi + s / max(r, 1e-4f); return float2(-c.x, c.y) + r * float2(cos(t), sin(t)); }
    s -= g.arc;
    if (s < g.lineV) { return float2(-c.x - r, c.y - s); }
    s -= g.lineV;
    if (s < g.arc) { float t = kPi + s / max(r, 1e-4f); return float2(-c.x, -c.y) + r * float2(cos(t), sin(t)); }
    s -= g.arc;
    if (s < g.lineH) { return float2(-c.x + s, -c.y - r); }
    s -= g.lineH;
    if (s < g.arc) { float t = 1.5f * kPi + s / max(r, 1e-4f); return float2(c.x, -c.y) + r * float2(cos(t), sin(t)); }
    s -= g.arc;
    return float2(c.x + r, -c.y + min(s, g.lineV));
}

// 1 behind the drawing tip, 0 beyond it, with a soft `feather` (points) at the tip. A full
// perimeter has no tip.
inline float gate(float sPts, float fill, float perimeter, float feather) {
    if (fill >= 0.9999f) { return 1.0f; }
    float tip = fill * perimeter;
    return 1.0f - smoothstep(tip - feather, tip, sPts);
}

// Coverage of the strip d in [-0.5, width] (the part under the card never shows).
inline float strip(float d, float width, float aa) {
    return clamp((d + 0.5f) / aa + 0.5f, 0.0f, 1.0f) * clamp((width - d) / aa + 0.5f, 0.0f, 1.0f);
}

} // namespace rim

[[ stitchable ]] half4 sectionRim(float2 position, half4 color, float2 size, float radius,
                                  float reach, float rtl, float dark, float scale,
                                  float baseFill, float baseA, float lineFill, float lineA,
                                  float headA, float haloLevel, half4 tint) {
    float2 q = position - (size * 0.5f + reach);
    if (rtl > 0.5f) { q.x = -q.x; }
    rim::Geometry g = rim::makeGeometry(size, radius);
    float d = rim::signedDistance(q, g);
    if (d > reach || d < -0.5f) { return half4(0.0h); }

    float aa = 1.0f / max(scale, 1.0f);
    float sPts = rim::arcLength(q, g);
    float P = g.perimeter;
    float outside = max(d, 0.0f);

    // Halo: the playground's two 3 pt strokes (blurred sigma 6 and 18, opacities level*1.6*tone
    // and level*1.1*tone) reduce to half-Gaussians from the edge. The stroke sits 0.8 pt inside.
    float tone = dark > 0.5f ? 1.1f : 0.85f;
    float dh = outside + 0.8f;
    float near = min(1.0f, haloLevel * 1.6f * tone) * 0.19947f * exp(-dh * dh / 72.0f);
    float far = min(1.0f, haloLevel * 1.1f * tone) * 0.06649f * exp(-dh * dh / 648.0f);
    float haloGate = rim::gate(sPts, max(baseFill, lineFill), P, 24.0f);
    float a = 1.0f - (1.0f - near) * (1.0f - far);
    a *= haloGate;

    // Resting hairline and the flourish line over it.
    float base = baseA * rim::gate(sPts, baseFill, P, 4.0f) * rim::strip(d, 1.4f, aa);
    float line = lineA * rim::gate(sPts, lineFill, P, 4.0f) * rim::strip(d, 1.6f, aa);
    a = 1.0f - (1.0f - a) * (1.0f - base) * (1.0f - line);

    // The head: a bright dot at the drawing tip with a soft glow.
    if (headA > 0.001f) {
        float2 tip = rim::pointAt(lineFill * P, g);
        float2 n = tip - clamp(tip, -g.inner, g.inner);
        tip += n / max(length(n), 1e-4f) * 0.7f;
        float dist = length(q - tip);
        float dot = clamp((1.75f - dist) / aa + 0.5f, 0.0f, 1.0f) * 0.95f;
        float glow = 0.30f * exp(-dist * dist / 24.5f);
        a = 1.0f - (1.0f - a) * (1.0f - headA * max(dot, glow));
    }

    a = clamp(a, 0.0f, 1.0f);
    return half4(tint.rgb * half(a), half(a));
}
