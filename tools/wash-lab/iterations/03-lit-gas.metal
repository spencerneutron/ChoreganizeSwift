#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// Completion wash: a one-shot celebration drawn behind a day's cards when its last open chore
// is completed. Its motion is a wave washing up a beach, seen from above: it rolls in from the
// lower trailing corner, fills the screen, lingers and turns, then drains back out. Its
// material is a lit, matte gas: the app icon's two colours billow and blend in soft gradients,
// lit from where the wave enters, with a warm glow at the leading edge. There are no hard
// edges, foam lines or highlights.
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
//   look      DEBUG look variant: 0 corner (default), 1 calm (smoother haze), 2 straight up
//   strength  0...1 opacity scale (1 on iOS; lower where rows sit on the background, e.g. Mac)
//
// Colours are mixed in OKLab (Björn Ottosson) so amber and lavender meet without the grey
// midpoint of an sRGB blend. Inputs are taken as gamma-encoded sRGB, the working space of the
// incoming pixel.
//
// Cost: pixels well ahead of the rolling front return early. Covered pixels evaluate about 24
// value-noise lookups (a two-layer domain warp of 3-octave fBm, three 2-octave light taps,
// the front's lobes and the dither).

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

    float width = max(size.x, 1.0);
    float height = max(size.y, 1.0);
    // How far the wave has to travel to reach this pixel, as a fraction: 0 at its origin, 1 at
    // the far corner. By default it rolls in from the lower trailing corner (the "straight"
    // look rises from the bottom edge instead).
    float2 uv = position / float2(width, height);
    float up = look > 1.5 ? 1.0 - uv.y : 0.68 * (1.0 - uv.y) + 0.32 * (1.0 - uv.x);
    // Feature units: one unit ≈ a phone's width, so billows keep their physical size on an iPad
    // or a Mac instead of stretching.
    float2 p = position / 320.0;

    // The wave's motion: it rushes in and slows (ease-out), lingers while the gas keeps
    // turning, then drains back with gathering speed (ease-in).
    float climb = 1.0 - pow(1.0 - saturate(tau / 0.34), 3.0);
    float drain = saturate((tau - 0.60) / 0.40);
    drain *= drain;
    // A slow breath while it lingers, so the front never sits still.
    float breath = 0.025 * sin(time * 2.1 + seed);
    float reach = mix(-0.30, 1.45, climb) + breath - 1.85 * drain;

    // Well ahead of the rolling front there's nothing to draw.
    if (drain <= 0.0 && reach - up < -0.42) { return color; }

    // The gas carries its pattern: it rides in with the wave and back out as it drains, along
    // the wave's own direction.
    float2 along = look > 1.5 ? float2(0.0, 1.0) : normalize(float2(0.32, 0.68));
    float2 q0 = p * 0.85 + float2(seed * 1.7, seed * 0.6) + along * reach * (height / 320.0) * 0.5;

    // Domain-warped fBm (Inigo Quilez), low frequency and few octaves: big soft billows that
    // swirl and fold into each other, with no fine detail or hard seams. The calm look warps
    // less, for a smoother haze.
    float warp = look > 0.5 && look < 1.5 ? 1.6 : 2.6;
    float2 q = float2(wash::fbm(q0 + time * float2(0.12, 0.04), 3),
                      wash::fbm(q0 + float2(5.2, 1.3) - time * float2(0.05, 0.10), 3));
    float2 r = float2(wash::fbm(q0 + warp * q + float2(1.7, 9.2) + 0.22 * time, 3),
                      wash::fbm(q0 + warp * q + float2(8.3, 2.8) - 0.18 * time, 3));
    float2 qd = q0 + 2.4 * r;
    float density = wash::fbm(qd, 3);

    // The front is a wide billowing gradient rather than a line: the gas's own density pushes
    // it ahead in places and holds it back in others.
    float lobes = 0.07 * (wash::noise(float2(dot(p, float2(along.y, -along.x)) * 1.6 + seed, time * 0.3)) - 0.5);
    float depth = reach + lobes + 0.22 * (density - 0.5) - up;
    float cover = smoothstep(-0.16, 0.24, depth);

    // Lit, matte: light comes from where the wave enters. Three short steps toward the light
    // sample how much gas is in the way (the same warp, fewer octaves), then Beer's law dims
    // the shadowed side and a "powder" term keeps the lit faces soft rather than glossy.
    float2 toLight = look > 1.5 ? float2(0.0, 0.55) : float2(0.38, 0.40);
    float shadowing = 0.0;
    for (int k = 1; k <= 3; k++) {
        shadowing += wash::fbm(qd + toLight * float(k), 2);
    }
    shadowing = max(shadowing - 1.2, 0.0);            // only gas denser than average shadows
    float beer = exp(-1.1 * shadowing);
    float powder = 1.0 - exp(-2.5 * (shadowing + 0.3));
    float lit = beer * powder;

    // Colour: a broad OKLab gradient between the two colours, steered by the swirl. Amber
    // leads at the front and sits high, like the icon; lavender gathers deep in the body. The
    // wide transition keeps them blending, with chroma lifted through the middle so the blend
    // stays a colour rather than a grey.
    float thickness = smoothstep(0.2, 0.8, density);
    float field = 0.55 * density + 0.45 * r.y + 0.30 * (0.45 - uv.y) - 0.26 * exp(-max(depth, 0.0) / 0.25);
    float mixer = smoothstep(0.26, 0.74, field);
    if (dark > 0.5) {
        // At night thin gas falls to lavender, so amber only shows where it glows brightest
        // (dim amber over black reads as khaki).
        mixer = max(mixer, 1.0 - smoothstep(0.35, 0.85, thickness * (0.55 + 0.45 * lit)));
    }
    float3 labA = wash::toOklab(float3(colorA.rgb));
    float3 labB = wash::toOklab(float3(colorB.rgb));
    float3 lab = mix(labA, labB, mixer);
    lab.yz *= 1.0 + 0.30 * sin(3.14159 * mixer);
    // Warm light, cool shadow: shadowed gas deepens toward a saturated periwinkle instead of
    // greying, and lit faces lift a little.
    float3 labShadow = float3(labB.x * 0.88, labB.yz * 1.3);
    lab = mix(lab, labShadow, 0.38 * (1.0 - lit));
    // In the dark the light adds rather than the shadow taking away, so the cores glow.
    lab.x *= dark > 0.5 ? mix(1.0, 1.10, lit) : mix(0.94, 1.04, lit);
    float3 gas = wash::fromOklab(lab);
    // Lit faces catch a broad, matte warmth from the glow colour.
    gas = mix(gas, float3(glow.rgb), 0.22 * lit * thickness);

    // Glow: a broad warm bloom rides just behind the front (the App Store creative's honey
    // highlight), strongest on the lit faces, fading as the wave drains.
    float bloom = exp(-pow((depth - 0.12) / 0.20, 2.0)) * (1.0 - 0.7 * drain) * (0.6 + 0.4 * lit);
    gas = mix(gas, float3(glow.rgb), 0.55 * bloom);

    // Thicker gas is more opaque; thin gas lets the background through, so it reads as wisps.
    float alpha = dark > 0.5 ? cover * mix(0.40, 0.95, thickness)
                             : cover * mix(0.66, 0.92, thickness);
    // As it drains it also thins out, and the whole thing eases away over the last tenth.
    alpha *= 1.0 - 0.45 * drain;
    alpha *= (1.0 - smoothstep(0.88, 1.0, tau)) * strength;

    float3 result = mix(float3(color.rgb), gas, alpha);
    // Triangular dither, about one step of 8-bit, so the soft gradients don't band on flat
    // backgrounds (strongest in dark mode).
    float2 grain = position + time * 37.0;
    float dither = (wash::hash(floor(grain)) + wash::hash(floor(grain + 71.0)) - 1.0) / 255.0;
    result += dither * alpha;
    return half4(half3(result), color.a);
}
