#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// Perfect-day glow (#57): adds a slow traveling specular highlight + glassy core to an
// already-green bar, for a calendar day whose chores were all completed. Used as a SwiftUI
// `colorEffect`, so `position` (view-space px) and `color` (current pixel) are implicit;
// custom params follow in order: time (s), view size (px), slot, slots, tilt (-1...1),
// intensity (0...1).
//
// Streak conduction: a run of consecutive perfect days shares one sweep. `slots` is the run
// length and `slot` this bar's 0-based index in it, so a single highlight travels bar 0 → 1 →
// … across the whole run. A lone perfect day is just slot 0 of 1 (the band sweeps it directly).
//
// `tilt` is device roll (-1...1); it slides the highlight, so the glow is alive in the hand and
// still when the phone is set down. 0 where device motion is unavailable (e.g. the Simulator).
[[ stitchable ]] half4 perfectDayGlow(float2 position, half4 color,
                                      float time, float2 size,
                                      float slot, float slots,
                                      float tilt, float intensity) {
    if (color.a < 0.01h) { return color; }          // never light pixels outside the bar

    float2 uv = position / size;                     // 0...1 across the bar

    // Global sweep position across the whole streak (0...1), nudged by device tilt; this bar's
    // local highlight coordinate places the band as it relays from one day to the next.
    float global = fract(time * 0.18) + tilt * 0.35;
    float center = global * slots - slot;
    float dx = uv.x - center;
    float band = exp(-(dx * dx) / (2.0 * 0.02));     // gaussian highlight

    // Brightest along the centerline -> a glassy core.
    float core = 1.0 - smoothstep(0.0, 0.5, fabs(uv.y - 0.5));
    half hi = half(band * (0.45 + 0.55 * core) * intensity);

    // A hair of mint on the leading edge sells "energy" vs. just "bright".
    half3 edge = half3(0.6h, 1.0h, 0.85h);
    half3 tinted = mix(color.rgb, edge, half(smoothstep(0.0, 0.04, dx) * 0.25 * intensity));

    // White-hot toward the band center, clamped by the original alpha.
    half3 lit = tinted + hi * (half3(1.0h) - tinted);
    return half4(lit, color.a);
}
