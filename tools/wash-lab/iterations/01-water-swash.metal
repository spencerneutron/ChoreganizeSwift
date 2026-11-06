#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// Completion wash: a one-shot celebration drawn behind a day's cards when its last open chore
// is completed. Its motion is a wave washing up a beach, seen from above: it rolls in from the
// bottom edge, fills the screen, swirls, then drains back down. Its material is a lit, matte
// gas: the app icon's two colours billow and blend in soft gradients with a warm glow at the
// leading edge. There are no hard edges, foam lines or highlights.
//
// Used as a SwiftUI `colorEffect` on a rectangle filled with the list's background, so
// `position` (points) and `color` (the background pixel) are implicit. Custom parameters
// follow in order:
//   size      the layer's size in points
//   time      seconds since the wash started
//   duration  the whole effect's length in seconds (it is transparent at and after it)
//   seed      varies the billows from one wash to the next
//   colorA    the warm colour (amber), colorB the cool colour (lavender), glow the bloom (honey)
//   dark      1 in dark appearance, else 0
//   look      DEBUG look variant: 0 billow (default), 1 calm (smoother haze), 2 diagonal
//   strength  0...1 opacity scale (1 on iOS; lower where rows sit on the background, e.g. Mac)
//
// Colours are mixed in OKLab (Björn Ottosson) so amber and lavender meet without the grey
// midpoint of an sRGB blend. Inputs are taken as gamma-encoded sRGB, the working space of the
// incoming pixel.
//
// Cost: pixels well ahead of the rolling front return early. Covered pixels evaluate 16
// value-noise lookups (a two-layer domain warp of 3-octave fBm, plus the front's lobes).

namespace wash {

// Integer lattice hash → 0...1. Stable on every GPU (sin-based hashes band at large inputs).
inline float hash(float2 cell) {
    uint2 q = uint2(int2(cell)) * uint2(1597334673u, 3812015801u);
    uint n = (q.x ^ q.y) * 1597334673u;
    return float(n) * (1.0 / 4294967295.0);
}

inline float noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + float2(1, 0));
    float c = hash(i + float2(0, 1));
    float d = hash(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Fractal noise normalised to 0...1 (mean ≈ 0.5). Each octave is rotated to hide the grid.
inline float fbm(float2 p, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    float total = 0.0;
    const float2x2 turn = float2x2(0.8, 0.6, -0.6, 0.8);
    for (int k = 0; k < octaves; k++) {
        value += amplitude * noise(p);
        total += amplitude;
        p = turn * p * 2.03 + 17.1;
        amplitude *= 0.5;
    }
    return value / total;
}

// sRGB transfer functions, per channel (scalar on purpose: the wash lab converts this file to
// WebGL, where vector comparisons are spelled differently).
inline float toLinear1(float c) {
    float a = abs(c);
    return sign(c) * (a <= 0.04045 ? a / 12.92 : powr((a + 0.055) / 1.055, 2.4));
}

inline float toGamma1(float c) {
    float a = abs(c);
    return sign(c) * (a <= 0.0031308 ? a * 12.92 : 1.055 * powr(a, 1.0 / 2.4) - 0.055);
}

inline float3 toLinear(float3 c) { return float3(toLinear1(c.r), toLinear1(c.g), toLinear1(c.b)); }
inline float3 toGamma(float3 c) { return float3(toGamma1(c.r), toGamma1(c.g), toGamma1(c.b)); }

inline float cubeRoot(float x) { return sign(x) * powr(abs(x), 1.0 / 3.0); }

inline float3 toOklab(float3 rgb) {
    float3 c = toLinear(rgb);
    float l = cubeRoot(0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b);
    float m = cubeRoot(0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b);
    float s = cubeRoot(0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b);
    return float3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                  1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                  0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s);
}

inline float3 fromOklab(float3 lab) {
    float l = lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z;
    float m = lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z;
    float s = lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z;
    l = l * l * l; m = m * m * m; s = s * s * s;
    float3 c = float3( 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                      -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s);
    return toGamma(c);
}

} // namespace wash

[[ stitchable ]] half4 choreWash(float2 position, half4 color,
                                 float2 size, float time, float duration, float seed,
                                 half4 colorA, half4 colorB, half4 glow,
                                 float dark, float look, float strength) {
    float tau = time / max(duration, 0.001);
    if (tau <= 0.0 || tau >= 1.0) { return color; }

    float height = max(size.y, 1.0);
    float up = 1.0 - position.y / height;
    if (look > 1.5) {
        up = 0.72 * up + 0.28 * (position.x / max(size.x, 1.0));
    }
    float2 p = position / 320.0;

    float climb = 1.0 - pow(1.0 - saturate(tau / 0.40), 3.0);
    float drain = saturate((tau - 0.52) / 0.36);
    drain *= drain;
    float reach = mix(-0.16, 1.24, climb) - 1.5 * drain;

    float lobes = 0.11 * (wash::noise(float2(p.x * 2.1 + seed, time * 0.35)) - 0.5)
                + 0.06 * (wash::noise(float2(p.x * 5.3 - seed, time * 0.6 + 4.0)) - 0.5);
    float depth = reach + lobes - up;

    if (drain <= 0.0 && depth < -0.05) { return color; }

    float2 q0 = p + float2(seed * 1.7, reach * (height / 320.0) * 0.55);

    float2 q = float2(wash::fbm(q0 * 1.1 + time * float2(0.10, 0.05), 3),
                      wash::fbm(q0 * 1.1 + float2(5.2, 1.3) - time * float2(0.06, 0.12), 3));
    float2 r = float2(wash::fbm(q0 * 1.1 + 3.2 * q + float2(1.7, 9.2) + 0.25 * time, 3),
                      wash::fbm(q0 * 1.1 + 3.2 * q + float2(8.3, 2.8) - 0.21 * time, 3));
    float swirl = wash::fbm(q0 * 1.1 + 3.0 * r, 4);

    float under = saturate(depth);
    float field = swirl + under * 0.22 - 0.15;
    float mixer = smoothstep(0.42, 0.58, field);
    float3 water = wash::fromOklab(mix(wash::toOklab(float3(colorA.rgb)),
                                       wash::toOklab(float3(colorB.rgb)), mixer));

    float shallow = exp(-max(depth, 0.0) / 0.045);
    water = mix(water, float3(glow.rgb), 0.38 * shallow * (1.0 - drain));

    float ridge = 1.0 - abs(2.0 * wash::fbm(q0 * 2.6 + 1.6 * r + time * 0.3, 3) - 1.0);
    float caustic = pow(ridge, 14.0) * 0.45 * (1.0 - drain);
    water += caustic * (1.0 - water);

    float soft = mix(0.006, 0.08, saturate(drain * 1.6));
    float cover = smoothstep(-soft * 0.3, soft, depth);
    float alpha = cover * (0.62 + 0.26 * smoothstep(0.0, 0.12, depth));
    if (dark > 0.5) {
        float core = smoothstep(0.04, 0.22, abs(field - 0.5));
        alpha = cover * mix(0.28, 0.92, core);
    }

    float foam = 0.0;
    float depthPts = depth * height;
    if (look < 0.5 || look > 1.5) {
        float bubbles = smoothstep(0.38, 0.56, wash::fbm(q0 * 15.0 + float2(seed * 3.1, -time * 0.9), 2));
        float lace = wash::fbm(q0 * 6.0 + float2(seed * 1.3, -time * 0.7), 3);
        float line = smoothstep(-1.0, 1.2, depthPts) * exp(-max(depthPts, 0.0) / 10.0) * (1.0 - drain);
        float edge = line * (0.45 + 0.55 * bubbles);
        float trail = step(0.0, depth) * exp(-depth / 0.08) * smoothstep(0.56, 0.70, lace) * bubbles
                    * 0.8 * (1.0 - drain);
        float strand = step(depth, 0.0) * drain * (1.0 - drain) * 2.4
                     * smoothstep(0.60, 0.74, lace) * bubbles * exp(depth / 0.25);
        foam = saturate(max(max(edge, trail), strand));
    }

    float wet = step(depth, 0.0) * smoothstep(0.0, 0.3, drain) * (1.0 - smoothstep(0.55, 1.0, tau))
              * 0.22 * smoothstep(-1.3, -0.02, depth);
    alpha = max(alpha, wet);

    float3 foamColor = dark > 0.5 ? mix(float3(glow.rgb), float3(1.0), 0.45) * 0.92
                                  : mix(float3(1.0), float3(glow.rgb), 0.22);
    float3 tint = mix(water, foamColor, foam);
    alpha = max(alpha, foam * 0.95);
    alpha *= (1.0 - smoothstep(0.9, 1.0, tau)) * strength;

    float3 base = float3(color.rgb);
    float wetLine = smoothstep(-8.0, -0.5, depthPts) * (1.0 - smoothstep(-0.5, 0.5, depthPts)) * (1.0 - drain);
    base = mix(base, base * (dark > 0.5 ? 1.0 : 0.9) * mix(float3(1.0), float3(colorB.rgb), 0.25),
               wetLine * (1.0 - smoothstep(0.9, 1.0, tau)));
    return half4(half3(mix(base, tint, alpha)), color.a);
}
