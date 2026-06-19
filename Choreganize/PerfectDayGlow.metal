#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// Perfect-day glow (#57): adds a slow traveling specular highlight + glassy core to an
// already-green bar, for a calendar day whose chores were all completed. Used as a SwiftUI
// `colorEffect`, so `position` (view-space px) and `color` (current pixel) are implicit;
// custom params follow in order: time (s), view size (px), tilt (-1...1), intensity (0...1).
//
// `tilt` is reserved for a future device-motion-reactive sweep (passed 0 today). Keeping it
// in the signature means wiring CoreMotion later needs no shader change.
[[ stitchable ]] half4 perfectDayGlow(float2 position, half4 color,
                                      float time, float2 size,
                                      float tilt, float intensity) {
    if (color.a < 0.01h) { return color; }          // never light pixels outside the bar

    float2 uv = position / size;                     // 0...1 across the bar

    // A specular band glides left -> right slowly; tilt nudges it (0 until motion is wired).
    float center = fract(time * 0.18) + tilt * 0.35;
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
