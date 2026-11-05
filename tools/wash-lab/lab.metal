// Wash lab kernel: renders the app's shipping `choreWash` shader (included verbatim, so the
// lab can never drift from the app) over a mock of the Work view's inset-grouped cards.
// `[[ stitchable ]]` makes the function a dynamically linked visible function; the lab calls it
// directly, so the attribute is compiled away here (the app build is unaffected).
#define stitchable
#ifndef WASH_SRC
#define WASH_SRC "../../Choreganize/ChoreWash.metal"
#endif
#include WASH_SRC
#ifndef RIM_SRC
#define RIM_SRC "../../Choreganize/SectionRim.metal"
#endif
#include RIM_SRC

struct LabParams {
    float2 size;        // canvas in points
    float scale;        // pixels per point
    float time;
    float duration;
    float seed;
    float dark;
    float look;
    float motion;
    float cards;        // 1 = draw the mock cards on top
    float4 base;
    float4 colorA;
    float4 colorB;
    float4 glow;
    float4 card;
    float4 ink;         // mock text bars
};

// Signed distance to a rounded rectangle given by its origin, size and corner radius.
static float roundedRect(float2 p, float2 origin, float2 extent, float radius) {
    float2 center = origin + extent * 0.5;
    float2 q = abs(p - center) - extent * 0.5 + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

static float bar(float2 p, float2 origin, float2 extent) {
    return roundedRect(p, origin, extent, extent.y * 0.5);
}

kernel void lab(texture2d<half, access::write> out [[texture(0)]],
                constant LabParams& P [[buffer(0)]],
                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
    float2 pos = (float2(gid) + 0.5) / P.scale;
    half4 c = choreWash(pos, half4(P.base), P.size, P.time, P.duration, P.seed,
                        half4(P.colorA), half4(P.colorB), half4(P.glow), P.dark, P.look, P.motion, 1.0);
    if (P.cards > 0.5) {
        float w = P.size.x;
        float aa = 0.6 / P.scale;
        // Date header on the background, like "Wednesday, Nov 4, 2026".
        float header = bar(pos, float2(52, 138), float2(170, 13));
        c = mix(c, half4(P.ink * 0.85), half(smoothstep(aa, -aa, header)));
        // Chores card (5 rows) and the actions card.
        float cardA = roundedRect(pos, float2(32, 162), float2(w - 64, 370), 24);
        float cardB = roundedRect(pos, float2(32, 568), float2(w - 64, 150), 24);
        float inside = smoothstep(aa, -aa, min(cardA, cardB));
        c = mix(c, half4(P.card), half(inside));
        for (int row = 0; row < 5; row++) {
            float y = 162 + 74 * row;
            float title = bar(pos, float2(52, y + 22), float2(120 + 30 * (row % 3), 12));
            float sub = bar(pos, float2(52, y + 42), float2(70, 9));
            float knob = roundedRect(pos, float2(w - 32 - 20 - 62, y + 22), float2(62, 30), 15);
            c = mix(c, half4(P.ink), half(smoothstep(aa, -aa, title)));
            c = mix(c, half4(P.ink * 0.55 + P.card * 0.45), half(smoothstep(aa, -aa, sub)));
            c = mix(c, half4(0.204h, 0.78h, 0.349h, 1.0h), half(smoothstep(aa, -aa, knob)));
        }
        for (int row = 0; row < 3; row++) {
            float y = 568 + 50 * row;
            float label = bar(pos, float2(84, y + 19), float2(110, 12));
            c = mix(c, half4(0.0h, 0.48h, 1.0h, 1.0h), half(smoothstep(aa, -aa, label)));
        }
    }
    out.write(c, gid);
}

// Rim mode: renders the app's shipping `sectionRim` shader, then the card ON TOP of it, as the
// app layers them (the rim sits behind an opaque List card).
struct RimParams {
    float2 size;        // canvas in points
    float2 cardSize;
    float radius;
    float reach;
    float scale;
    float dark;
    float rtl;
    float baseFill, baseA, lineFill, lineA, headA, haloLevel;
    float4 page;
    float4 card;
    float4 tint;
};

kernel void rimLab(texture2d<half, access::write> out [[texture(0)]],
                   constant RimParams& P [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
    float2 pos = (float2(gid) + 0.5) / P.scale;
    // The layer is the card outset by the reach, centred on the canvas.
    float2 layerSize = P.cardSize + 2.0 * P.reach;
    float2 origin = (P.size - layerSize) * 0.5;
    float2 local = pos - origin;
    half4 rim = sectionRim(local, half4(0.0h), P.cardSize, P.radius, P.reach, P.rtl, P.dark, P.scale,
                           P.baseFill, P.baseA, P.lineFill, P.lineA, P.headA, P.haloLevel, half4(P.tint));
    if (local.x < 0 || local.y < 0 || local.x > layerSize.x || local.y > layerSize.y) { rim = half4(0.0h); }
    half4 c = half4(half3(P.page.rgb) * (1.0h - rim.a) + rim.rgb, 1.0h);   // premultiplied over the page
    float aa = 0.6 / P.scale;
    float2 centre = P.size * 0.5;
    float d = roundedRect(pos, centre - P.cardSize * 0.5, P.cardSize, P.radius);
    c = mix(c, half4(P.card), half(smoothstep(aa, -aa, d)));
    out.write(c, gid);
}
