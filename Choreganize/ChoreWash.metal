#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// Completion wash: a one-shot celebration drawn behind a day's cards when its last open chore
// is completed. Its motion is a wave washing up a beach, seen from above: it rolls in from the
// lower trailing corner, fills the screen, lingers and turns, then drains back out (or rolls
// through). Its material is a nebula seen up close: a small volume of slices, each a lit,
// matte gas in the app icon's two colours, with luminous filaments, dark dust lanes and thin
// bright rims where clumps face the star that lights them. There are no hard edges or specular
// highlights.
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
//             (the lamp sits off the entry corner, or below the bottom edge for look 2)
//   motion    0 = expand and retreat (rolls in, lingers, drains back out); 1 = roll-through (enters
//             at the corner, slows through the middle, exits at the far corner, never reverses)
//   strength  0...1 opacity scale (1 on iOS; lower where rows sit on the background, e.g. Mac)
//
// Colours are mixed in OKLab (Björn Ottosson) so amber and lavender meet without the grey
// midpoint of an sRGB blend. Inputs are taken as gamma-encoded sRGB, the working space of the
// incoming pixel.
//
// Cost: pixels well ahead of the rolling front return early. Covered pixels evaluate about 54
// value-noise lookups: a shared two-layer domain warp (12), the front (4), and four volume
// slices of 9 each (3-octave density, two 2-octave light taps, a 2-octave dust field), plus
// the dither.

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
                                 float dark, float look, float motion, float strength) {
    float tau = time / max(duration, 0.001);
    if (tau <= 0.0 || tau >= 1.0) { return color; }

    float width = max(size.x, 1.0);
    float height = max(size.y, 1.0);
    // How far the wave has to travel to reach this pixel, as a fraction: 0 at its origin, 1 at
    // the far corner. By default it rolls in from the lower trailing corner (the "straight"
    // look rises from the bottom edge instead).
    float2 uv = position / float2(width, height);
    bool straight = look > 1.5;
    float up = straight ? 1.0 - uv.y : 0.68 * (1.0 - uv.y) + 0.32 * (1.0 - uv.x);
    // Feature units: one unit ≈ a phone's width, so billows keep their physical size on an iPad
    // or a Mac instead of stretching.
    float2 p = position / 320.0;

    // The wave's motion. Expand and retreat: it rushes in and slows (ease-out), lingers while
    // the gas keeps turning, then drains back with gathering speed (ease-in). Roll-through: one
    // monotonic pass that enters fast, slows through the middle and leaves fast, with a tail a
    // screen-and-a-bit long so the whole cloud crosses and exits at the far corner.
    bool rolls = motion > 0.5;
    float climb = 1.0 - pow(1.0 - saturate(tau / 0.34), 3.0);
    float drain = rolls ? 0.0 : saturate((tau - 0.60) / 0.40);
    drain *= drain;
    float breath = 0.025 * sin(time * 2.1 + seed);
    // Long enough that the tail clears the far corner only at the end of the duration.
    const float cloudLength = 1.6;
    float pass = tau + 0.12 * sin(6.28318 * tau);
    float reach = rolls ? mix(-0.30, 1.45 + cloudLength + 0.05, pass) + breath
                        : mix(-0.30, 1.45, climb) + breath - 1.85 * drain;
    float tail = reach - cloudLength;

    // The light source: a star just off the corner the wave enters from. Its light spills onto
    // the page a beat before the gas arrives and holds through the linger.
    float2 origin = straight ? float2(0.5, 1.12) : float2(1.06, 1.06);
    float2 toOrigin = (uv - origin) * float2(width / height, 1.0);
    // At night the star's glow is broader and dimmer, so it arrives as gradually as the gas.
    float lamp = exp(-dot(toOrigin, toOrigin) / (dark > 0.5 ? 0.55 : 0.34));
    float lampEnv = smoothstep(0.0, 0.26, tau) * (1.0 - smoothstep(rolls ? 0.40 : 0.62, rolls ? 0.80 : 0.96, tau));
    float lampGlow = lamp * lampEnv;
    float3 spillColor = dark > 0.5 ? mix(float3(glow.rgb), float3(1.0), 0.35) : float3(glow.rgb);
    float3 page = float3(color.rgb);
    float fade = (1.0 - smoothstep(0.88, 1.0, tau)) * strength;

    if ((drain <= 0.0 && reach - up < -0.42) || (rolls && tail - up > 0.42)) {
        return half4(half3(mix(page, spillColor, 0.30 * lampGlow * strength)), color.a);
    }

    // One shared swirl for every layer: a two-layer domain warp (Inigo Quilez) in a frame that
    // moves with the cloud, so the whole volume churns together.
    float2 along = straight ? float2(0.0, 1.0) : normalize(float2(0.32, 0.68));
    float advect = reach * (height / 320.0);
    float2 base = p * 0.85 + float2(seed * 1.7, seed * 0.6);
    float2 q0 = base + along * advect * 0.5;
    float warp = look > 0.5 && look < 1.5 ? 1.6 : 2.6;
    float2 q = float2(wash::fbm(q0 + time * float2(0.12, 0.04), 3),
                      wash::fbm(q0 + float2(5.2, 1.3) - time * float2(0.05, 0.10), 3));
    float2 r = float2(wash::fbm(q0 + warp * q + float2(1.7, 9.2) + 0.22 * time, 3),
                      wash::fbm(q0 + warp * q + float2(8.3, 2.8) - 0.18 * time, 3));
    float2 swirl = 2.4 * r;

    // The front is a wide billowing gradient rather than a line: the gas's own density pushes
    // it ahead in places and holds it back in others.
    float densityC = wash::fbm(q0 + swirl, 3);
    float lobes = 0.07 * (wash::noise(float2(dot(p, float2(along.y, -along.x)) * 1.6 + seed, time * 0.3)) - 0.5);
    float depth = reach + lobes + 0.22 * (densityC - 0.5) - up;
    // Over a light page the gas tints its way in; over black it would switch on. So at night
    // the front and tail are wider, and (below) a dim ambient haze arrives with them.
    float soft = dark > 0.5 ? 1.8 : 1.0;
    float cover = smoothstep(-0.16 * soft, 0.24 * soft, depth);
    if (rolls) {
        float behind = tail + lobes + 0.22 * (densityC - 0.5) - up;
        cover *= 1.0 - smoothstep(-0.24 * soft, 0.16 * soft, behind);
    }

    // The volume: four slices from far to near, composited with the "over" operator. Each slice
    // is a warped density field with its own parallax (far slices drift slower and coarser),
    // lit by two taps toward the star (Beer's law), coloured by density on an OKLab ramp (thin
    // lavender → amber → a honey core), with a thin bright rim where a clump faces the light,
    // like an ionisation front. A separate dust field only absorbs: it darkens the slices and
    // the page behind it, so dark lanes silhouette against the glow.
    float3 labA = wash::toOklab(float3(colorA.rgb));
    float3 labB = wash::toOklab(float3(colorB.rgb));
    float3 labGlow = wash::toOklab(float3(glow.rgb));
    float2 toLight = straight ? float2(0.0, 0.55) : float2(0.36, 0.38);
    float3 pre = float3(0.0);          // premultiplied colour of the gas so far
    float opacity = 0.0;               // its coverage
    float3 pageShade = float3(1.0);    // dust between the page and the viewer, tinted not grey
    const float3 dustTint = float3(0.62, 0.60, 0.80);
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float zoom = 0.72 + 0.30 * fi;
        float2 qi = base * zoom + along * advect * (0.32 + 0.13 * fi) + float2(11.3, 7.1) * fi
                  + swirl * (0.75 + 0.12 * fi) + time * float2(0.035, -0.02) * (fi + 1.0);
        float d = wash::fbm(qi, 3);
        float toward = 0.5 * (wash::fbm(qi + toLight * 0.5, 2) + wash::fbm(qi + toLight * 1.1, 2));
        float lit = exp(-1.4 * max(toward - d, 0.0));
        float dust = smoothstep(0.55, 0.80, wash::fbm(qi * 1.9 + float2(5.0, 3.0) + fi, 2));
        // Dust in this slice darkens everything behind it, toward a deep lavender rather than grey.
        pre *= mix(float3(1.0), dustTint, 0.6 * dust);
        pageShade *= mix(float3(1.0), mix(float3(1.0), dustTint, 0.3), dark > 0.5 ? 0.0 : dust);

        float body = smoothstep(0.56, 0.86, d);          // lavender until the dense cores turn amber
        float em = pow(smoothstep(0.36, 0.90, d), 1.6);
        float a = 1.0 - exp(-1.8 * em);
        float3 lab = mix(labB, labA, body);
        lab.yz *= 1.0 + 0.30 * sin(3.14159 * body);
        lab = mix(lab, labGlow, smoothstep(0.86, 0.98, d) * lit);
        // Night keeps the gas within the same contrast band as day: lightness is compressed so
        // the cores read as peaks above the haze rather than flashes out of black.
        lab.x *= dark > 0.5 ? 0.74 * mix(0.88, 1.10, lit) : mix(0.90, 1.04, lit);
        // The rim: thin gas on the lit side of a clump glows like an ionisation front.
        float rim = smoothstep(0.26, 0.40, d) * (1.0 - smoothstep(0.40, 0.58, d)) * lit * lit;
        lab = mix(lab, labGlow, 0.45 * rim);
        float3 c = wash::fromOklab(lab);
        pre = pre * (1.0 - a) + c * a;
        opacity = opacity * (1.0 - a) + a;
    }

    // The star's light warms the gas nearest it and spills onto the bare page.
    pre += float3(glow.rgb) * (dark > 0.5 ? 0.35 : 0.22) * lampGlow * opacity;
    // Under the gas: the shaded page by day; by night a dusky lavender haze that stands in for
    // the light page, so thin gas deepens out of it instead of appearing from nothing.
    float3 ambient = wash::fromOklab(float3(0.33, labB.yz * 0.7));
    float3 under = dark > 0.5 ? mix(page, ambient, 0.85) : page * pageShade;
    float3 gas = saturate(pre) + under * (1.0 - opacity);
    gas = mix(gas, spillColor, 0.30 * lampGlow * (1.0 - opacity));
    float coverage = cover * fade;
    float3 result = mix(page, gas, coverage);

    // Triangular dither, about one step of 8-bit, so the soft gradients don't band on flat
    // backgrounds (strongest in dark mode).
    float2 grain = position + time * 37.0;
    float dither = (wash::hash(floor(grain)) + wash::hash(floor(grain + 71.0)) - 1.0) / 255.0;
    result += dither * coverage;
    return half4(half3(result), color.a);
}
